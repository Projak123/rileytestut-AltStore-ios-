//
//  AppManager.swift
//  AltStore
//
//  Created by Riley Testut on 5/29/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import Foundation
import UIKit
import UserNotifications
import MobileCoreServices

import AltSign
import AltKit

import Roxas

extension AppManager
{
    static let didFetchSourceNotification = Notification.Name("com.altstore.AppManager.didFetchSource")
    
    static let expirationWarningNotificationID = "altstore-expiration-warning"
}

class AppManager
{
    static let shared = AppManager()
    
    private let operationQueue = OperationQueue()
    private let serialOperationQueue = OperationQueue()
    
    private var installationProgress = [String: Progress]()
    private var refreshProgress = [String: Progress]()
    
    private init()
    {
        self.operationQueue.name = "com.altstore.AppManager.operationQueue"
        
        self.serialOperationQueue.name = "com.altstore.AppManager.serialOperationQueue"
        self.serialOperationQueue.maxConcurrentOperationCount = 1
    }
}

extension AppManager
{
    func update()
    {
        DatabaseManager.shared.persistentContainer.performBackgroundTask { (context) in
            #if targetEnvironment(simulator)
            // Apps aren't ever actually installed to simulator, so just do nothing rather than delete them from database.
            #else
            do
            {
                let installedApps = InstalledApp.all(in: context)
                
                if UserDefaults.standard.legacySideloadedApps == nil
                {
                    // First time updating apps since updating AltStore to use custom UTIs,
                    // so cache all existing apps temporarily to prevent us from accidentally
                    // deleting them due to their custom UTI not existing (yet).
                    let apps = installedApps.map { $0.bundleIdentifier }
                    UserDefaults.standard.legacySideloadedApps = apps
                }
                
                let legacySideloadedApps = Set(UserDefaults.standard.legacySideloadedApps ?? [])
                
                for app in installedApps
                {
                    guard app.bundleIdentifier != StoreApp.altstoreAppID else {
                        self.scheduleExpirationWarningLocalNotification(for: app)
                        continue
                    }
                    
                    guard !self.isActivelyManagingApp(withBundleID: app.bundleIdentifier) else { continue }
                    
                    let uti = UTTypeCopyDeclaration(app.installedAppUTI as CFString)?.takeRetainedValue() as NSDictionary?
                    if uti == nil && !legacySideloadedApps.contains(app.bundleIdentifier)
                    {
                        // This UTI is not declared by any apps, which means this app has been deleted by the user.
                        // This app is also not a legacy sideloaded app, so we can assume it's fine to delete it.
                        context.delete(app)
                    }
                }
                
                try context.save()
            }
            catch
            {
                print("Error while fetching installed apps.", error)
            }
            #endif
            
            do
            {
                let installedAppBundleIDs = InstalledApp.all(in: context).map { $0.bundleIdentifier }
                                
                let cachedAppDirectories = try FileManager.default.contentsOfDirectory(at: InstalledApp.appsDirectoryURL,
                                                                                       includingPropertiesForKeys: [.isDirectoryKey, .nameKey],
                                                                                       options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles])
                for appDirectory in cachedAppDirectories
                {
                    do
                    {
                        let resourceValues = try appDirectory.resourceValues(forKeys: [.isDirectoryKey, .nameKey])
                        guard let isDirectory = resourceValues.isDirectory, let bundleID = resourceValues.name else { continue }
                        
                        if isDirectory && !installedAppBundleIDs.contains(bundleID) && !self.isActivelyManagingApp(withBundleID: bundleID)
                        {
                            print("DELETING CACHED APP:", bundleID)
                            try FileManager.default.removeItem(at: appDirectory)
                        }
                    }
                    catch
                    {
                        print("Failed to remove cached app directory.", error)
                    }
                }
            }
            catch
            {
                print("Failed to remove cached apps.", error)
            }
        }
    }
    
    @discardableResult
    func findServer(context: OperationContext = OperationContext(), completionHandler: @escaping (Result<Server, Error>) -> Void) -> FindServerOperation
    {
        let findServerOperation = FindServerOperation(context: context)
        findServerOperation.resultHandler = { (result) in
            switch result
            {
            case .failure(let error): context.error = error
            case .success(let server): context.server = server
            }
        }
        
        self.run([findServerOperation], context: context)
        
        return findServerOperation
    }
    
    @discardableResult
    func authenticate(presentingViewController: UIViewController?, context: AuthenticatedOperationContext = AuthenticatedOperationContext(), completionHandler: @escaping (Result<(ALTTeam, ALTCertificate, ALTAppleAPISession), Error>) -> Void) -> AuthenticationOperation
    {
        if let operation = context.authenticationOperation
        {
            return operation
        }
        
        let findServerOperation = self.findServer(context: context) { _ in }
        
        let authenticationOperation = AuthenticationOperation(context: context, presentingViewController: presentingViewController)
        authenticationOperation.resultHandler = { (result) in
            switch result
            {
            case .failure(let error): context.error = error
            case .success: break
            }
            
            completionHandler(result)
        }
        authenticationOperation.addDependency(findServerOperation)
        
        self.run([authenticationOperation], context: context)
        
        return authenticationOperation
    }
}

extension AppManager
{
    func fetchSource(sourceURL: URL, completionHandler: @escaping (Result<Source, Error>) -> Void)
    {
        let fetchSourceOperation = FetchSourceOperation(sourceURL: sourceURL)
        fetchSourceOperation.resultHandler = { (result) in
            switch result
            {
            case .failure(let error):
                completionHandler(.failure(error))
                
            case .success(let source):
                completionHandler(.success(source))
            }
        }
        
        self.run([fetchSourceOperation], context: nil)
    }
    
    func fetchSources(completionHandler: @escaping (Result<Set<Source>, Error>) -> Void)
    {
        DatabaseManager.shared.persistentContainer.performBackgroundTask { (context) in
            let sources = Source.all(in: context)
            guard !sources.isEmpty else { return completionHandler(.failure(OperationError.noSources)) }
            
            let dispatchGroup = DispatchGroup()
            var fetchedSources = Set<Source>()
            var error: Error?
            
            let managedObjectContext = DatabaseManager.shared.persistentContainer.newBackgroundContext()
            
            let operations = sources.map { (source) -> FetchSourceOperation in
                dispatchGroup.enter()
                
                let fetchSourceOperation = FetchSourceOperation(sourceURL: source.sourceURL, managedObjectContext: managedObjectContext)
                fetchSourceOperation.resultHandler = { (result) in
                    switch result
                    {
                    case .failure(let e): error = e
                    case .success(let source): fetchedSources.insert(source)
                    }
                    
                    dispatchGroup.leave()
                }
                
                return fetchSourceOperation
            }
            
            dispatchGroup.notify(queue: .global()) {
                if let error = error
                {
                    completionHandler(.failure(error))
                }
                else
                {
                    managedObjectContext.perform {
                        completionHandler(.success(fetchedSources))
                    }
                }
                
                NotificationCenter.default.post(name: AppManager.didFetchSourceNotification, object: self)
            }
            
            self.run(operations, context: nil)
        }
    }
    
    func fetchAppIDs(completionHandler: @escaping (Result<([AppID], NSManagedObjectContext), Error>) -> Void)
    {
        let authenticationOperation = self.authenticate(presentingViewController: nil) { (result) in
            print("Authenticated for fetching App IDs with result:", result)
        }
        
        let fetchAppIDsOperation = FetchAppIDsOperation(context: authenticationOperation.context)
        fetchAppIDsOperation.resultHandler = completionHandler
        fetchAppIDsOperation.addDependency(authenticationOperation)
        self.run([fetchAppIDsOperation], context: authenticationOperation.context)
    }
    
    @discardableResult
    func install<T: AppProtocol>(_ app: T, presentingViewController: UIViewController?, context: AuthenticatedOperationContext = AuthenticatedOperationContext(), completionHandler: @escaping (Result<InstalledApp, Error>) -> Void) -> Progress
    {
        let group = RefreshGroup(context: context)
        group.completionHandler = { (results) in
            do
            {
                guard let result = results.values.first else { throw OperationError.unknown }
                completionHandler(result)
            }
            catch
            {
                completionHandler(.failure(error))
            }
        }
        
        let operation = AppOperation.install(app)
        self.perform([operation], presentingViewController: presentingViewController, group: group)
        
        return group.progress
    }
    
    @discardableResult
    func update(_ app: InstalledApp, presentingViewController: UIViewController?, context: AuthenticatedOperationContext = AuthenticatedOperationContext(), completionHandler: @escaping (Result<InstalledApp, Error>) -> Void) -> Progress
    {
        guard let storeApp = app.storeApp else {
            completionHandler(.failure(OperationError.appNotFound))
            return Progress.discreteProgress(totalUnitCount: 1)
        }
        
        let group = RefreshGroup(context: context)
        group.completionHandler = { (results) in
            do
            {
                guard let result = results.values.first else { throw OperationError.unknown }
                completionHandler(result)
            }
            catch
            {
                completionHandler(.failure(error))
            }
        }
        
        let operation = AppOperation.update(storeApp)
        assert(operation.app as AnyObject === storeApp) // Make sure we never accidentally "update" to already installed app.
        
        self.perform([operation], presentingViewController: presentingViewController, group: group)
        
        return group.progress
    }
    
    @discardableResult
    func refresh(_ installedApps: [InstalledApp], presentingViewController: UIViewController?, group: RefreshGroup? = nil) -> RefreshGroup
    {
        let group = group ?? RefreshGroup()
        
        let operations = installedApps.map { AppOperation.refresh($0) }
        return self.perform(operations, presentingViewController: presentingViewController, group: group)
    }
    
    func activate(_ installedApp: InstalledApp, presentingViewController: UIViewController?, completionHandler: @escaping (Result<InstalledApp, Error>) -> Void)
    {
        let group = self.refresh([installedApp], presentingViewController: presentingViewController)
        group.completionHandler = { (results) in
            do
            {
                guard let result = results.values.first else { throw OperationError.unknown }
                
                let installedApp = try result.get()
                installedApp.managedObjectContext?.perform {
                    installedApp.isActive = true
                    completionHandler(.success(installedApp))
                }
            }
            catch
            {
                completionHandler(.failure(error))
            }
        }
    }
    
    func deactivate(_ installedApp: InstalledApp, completionHandler: @escaping (Result<InstalledApp, Error>) -> Void)
    {
        let context = OperationContext()
        
        let findServerOperation = self.findServer(context: context) { _ in }
        
        let deactivateAppOperation = DeactivateAppOperation(app: installedApp, context: context)
        deactivateAppOperation.resultHandler = { (result) in
            completionHandler(result)
        }
        deactivateAppOperation.addDependency(findServerOperation)
        
        self.run([deactivateAppOperation], context: context, requiresSerialQueue: true)
    }
    
    func installationProgress(for app: AppProtocol) -> Progress?
    {
        let progress = self.installationProgress[app.bundleIdentifier]
        return progress
    }
    
    func refreshProgress(for app: AppProtocol) -> Progress?
    {
        let progress = self.refreshProgress[app.bundleIdentifier]
        return progress
    }
}

private extension AppManager
{
    enum AppOperation
    {
        case install(AppProtocol)
        case update(AppProtocol)
        case refresh(AppProtocol)
        
        var app: AppProtocol {
            switch self
            {
            case .install(let app), .update(let app), .refresh(let app): return app
            }
        }
        
        var bundleIdentifier: String {
            var bundleIdentifier: String!
            
            if let context = (self.app as? NSManagedObject)?.managedObjectContext
            {
                context.performAndWait { bundleIdentifier = self.app.bundleIdentifier }
            }
            else
            {
                bundleIdentifier = self.app.bundleIdentifier
            }
            
            return bundleIdentifier
        }
    }
    
    func isActivelyManagingApp(withBundleID bundleID: String) -> Bool
    {
        let isActivelyManaging = self.installationProgress.keys.contains(bundleID) || self.refreshProgress.keys.contains(bundleID)
        return isActivelyManaging
    }
    
    @discardableResult
    private func perform(_ operations: [AppOperation], presentingViewController: UIViewController?, group: RefreshGroup) -> RefreshGroup
    {
        let operations = operations.filter { self.progress(for: $0) == nil || self.progress(for: $0)?.isCancelled == true }
        
        for operation in operations
        {
            let progress = Progress.discreteProgress(totalUnitCount: 100)
            self.set(progress, for: operation)
        }
        
        if let viewController = presentingViewController
        {
            group.context.presentingViewController = viewController
        }
        
        /* Authenticate (if necessary) */
        var authenticationOperation: AuthenticationOperation?
        if group.context.session == nil
        {
            authenticationOperation = self.authenticate(presentingViewController: presentingViewController, context: group.context) { (result) in
                switch result
                {
                case .failure(let error): group.context.error = error
                case .success: break
                }
            }
        }
        
        func performAppOperations()
        {
            for operation in operations
            {
                let progress = self.progress(for: operation)
                
                if let progress = progress
                {
                    group.progress.totalUnitCount += 1
                    group.progress.addChild(progress, withPendingUnitCount: 1)
                    
                    if group.context.session != nil
                    {
                        // Finished authenticating, so increase completed unit count.
                        progress.completedUnitCount += 20
                    }
                }
                
                switch operation
                {
                case .refresh(let installedApp as InstalledApp) where installedApp.certificateSerialNumber == group.context.certificate?.serialNumber:
                    // Refreshing apps, but using same certificate as last time, so we can just refresh provisioning profiles.
                                        
                    let refreshProgress = self._refresh(installedApp, operation: operation, group: group) { (result) in
                        self.finish(operation, result: result, group: group, progress: progress)
                    }
                    progress?.addChild(refreshProgress, withPendingUnitCount: 80)
                    
                case .refresh(let app), .install(let app), .update(let app):
                    // Either installing for first time, or refreshing with a different signing certificate,
                    // so we need to resign the app then install it.
                    
                    let installProgress = self._install(app, operation: operation, group: group) { (result) in
                        self.finish(operation, result: result, group: group, progress: progress)
                    }
                    progress?.addChild(installProgress, withPendingUnitCount: 80)
                }
            }
        }
        
        if let authenticationOperation = authenticationOperation
        {
            let awaitAuthenticationOperation = BlockOperation {
                if let managedObjectContext = operations.lazy.compactMap({ ($0.app as? NSManagedObject)?.managedObjectContext }).first
                {
                    managedObjectContext.perform { performAppOperations() }
                }
                else
                {
                    performAppOperations()
                }
            }
            awaitAuthenticationOperation.addDependency(authenticationOperation)
            self.run([awaitAuthenticationOperation], context: group.context, requiresSerialQueue: true)
        }
        else
        {
            performAppOperations()
        }
        
        return group
    }
    
    private func _install(_ app: AppProtocol, operation: AppOperation, group: RefreshGroup, additionalEntitlements: [ALTEntitlement: Any]? = nil, completionHandler: @escaping (Result<InstalledApp, Error>) -> Void) -> InstallAppOperationContext
    {
        let progress = Progress.discreteProgress(totalUnitCount: 100)
        
        let context = InstallAppOperationContext(bundleIdentifier: app.bundleIdentifier, authenticatedContext: group.context)
        context.beginInstallationHandler = { (installedApp) in
            switch operation
            {
            case .update where installedApp.bundleIdentifier == StoreApp.altstoreAppID:
                // AltStore will quit before installation finishes,
                // so assume if we get this far the update will finish successfully.
                let event = AnalyticsManager.Event.updatedApp(installedApp)
                AnalyticsManager.shared.trackEvent(event)
                
            default: break
            }
            
            group.beginInstallationHandler?(installedApp)
        }
        
        var downloadingApp = app
        
        if let installedApp = app as? InstalledApp, let storeApp = installedApp.storeApp, !FileManager.default.fileExists(atPath: installedApp.fileURL.path)
        {
            // Cached app has been deleted, so we need to redownload it.
            downloadingApp = storeApp
        }
        
        /* Download */
        let downloadOperation = DownloadAppOperation(app: downloadingApp, context: context)
        downloadOperation.resultHandler = { (result) in
            switch result
            {
            case .failure(let error): context.error = error
            case .success(let app): context.app = app
            }
        }
        progress.addChild(downloadOperation.progress, withPendingUnitCount: 25)
        
        /* Verify App */
        let verifyOperation = VerifyAppOperation(context: context)
        verifyOperation.resultHandler = { (result) in
            switch result
            {
            case .failure(let error): context.error = error
            case .success: break
            }
        }
        verifyOperation.addDependency(downloadOperation)
        
        /* Refresh Anisette Data */
        let refreshAnisetteDataOperation = FetchAnisetteDataOperation(context: group.context)
        refreshAnisetteDataOperation.resultHandler = { (result) in
            switch result
            {
            case .failure(let error): context.error = error
            case .success(let anisetteData): group.context.session?.anisetteData = anisetteData
            }
        }
        refreshAnisetteDataOperation.addDependency(verifyOperation)
        
        
        /* Fetch Provisioning Profiles */
        let fetchProvisioningProfilesOperation = FetchProvisioningProfilesOperation(context: context)
        fetchProvisioningProfilesOperation.additionalEntitlements = additionalEntitlements
        fetchProvisioningProfilesOperation.resultHandler = { (result) in
            switch result
            {
            case .failure(let error): context.error = error
            case .success(let provisioningProfiles): context.provisioningProfiles = provisioningProfiles
            }
        }
        fetchProvisioningProfilesOperation.addDependency(refreshAnisetteDataOperation)
        progress.addChild(fetchProvisioningProfilesOperation.progress, withPendingUnitCount: 5)
        
        
        /* Resign */
        let resignAppOperation = ResignAppOperation(context: context)
        resignAppOperation.resultHandler = { (result) in
            switch result
            {
            case .failure(let error): context.error = error
            case .success(let resignedApp): context.resignedApp = resignedApp
            }
        }
        resignAppOperation.addDependency(fetchProvisioningProfilesOperation)
        progress.addChild(resignAppOperation.progress, withPendingUnitCount: 20)
        
        
        /* Send */
        let sendAppOperation = SendAppOperation(context: context)
        sendAppOperation.resultHandler = { (result) in
            switch result
            {
            case .failure(let error): context.error = error
            case .success(let installationConnection): context.installationConnection = installationConnection
            }
        }
        sendAppOperation.addDependency(resignAppOperation)
        progress.addChild(sendAppOperation.progress, withPendingUnitCount: 20)
        
        
        /* Install */
        let installOperation = InstallAppOperation(context: context)
        installOperation.resultHandler = { (result) in
            switch result
            {
            case .failure(let error): completionHandler(.failure(error))
            case .success(let installedApp):
                if let app = app as? StoreApp, let storeApp = installedApp.managedObjectContext?.object(with: app.objectID) as? StoreApp
                {
                    installedApp.storeApp = storeApp
                }
                
                if let index = UserDefaults.standard.legacySideloadedApps?.firstIndex(of: installedApp.bundleIdentifier)
                {
                    // No longer a legacy sideloaded app, so remove it from cached list.
                    UserDefaults.standard.legacySideloadedApps?.remove(at: index)
                }
                
                completionHandler(.success(installedApp))
            }
        }
        progress.addChild(installOperation.progress, withPendingUnitCount: 30)
        installOperation.addDependency(sendAppOperation)
        
        let operations = [downloadOperation, verifyOperation, refreshAnisetteDataOperation, fetchProvisioningProfilesOperation, resignAppOperation, sendAppOperation, installOperation]
        group.add(operations)
        self.run(operations, context: group.context)
        
        return progress
    }
    
    private func _refresh(_ app: InstalledApp, operation: AppOperation, group: RefreshGroup, completionHandler: @escaping (Result<InstalledApp, Error>) -> Void) -> Progress
    {
        let progress = Progress.discreteProgress(totalUnitCount: 100)
        
        let context = AppOperationContext(bundleIdentifier: app.bundleIdentifier, authenticatedContext: group.context)
        context.app = ALTApplication(fileURL: app.url)
           
        /* Fetch Provisioning Profiles */
        let fetchProvisioningProfilesOperation = FetchProvisioningProfilesOperation(context: context)
        fetchProvisioningProfilesOperation.resultHandler = { (result) in
            switch result
            {
            case .failure(let error): context.error = error
            case .success(let provisioningProfiles): context.provisioningProfiles = provisioningProfiles
            }
        }
        progress.addChild(fetchProvisioningProfilesOperation.progress, withPendingUnitCount: 60)
                
        /* Refresh */
        let refreshAppOperation = RefreshAppOperation(context: context)
        refreshAppOperation.resultHandler = { (result) in
            switch result
            {
            case .success(let installedApp):
                completionHandler(.success(installedApp))
                
            case .failure(ALTServerError.unknownRequest), .failure(OperationError.appNotFound):
                // Fall back to installation if AltServer doesn't support newer provisioning profile requests,
                // OR if the cached app could not be found and we may need to redownload it.
                app.managedObjectContext?.performAndWait { // Must performAndWait to ensure we add operations before we return.
                    let installProgress = self._install(app, operation: operation, group: group) { (result) in
                        completionHandler(result)
                    }
                    progress.addChild(installProgress, withPendingUnitCount: 40)
                }
                
            case .failure(let error):
                completionHandler(.failure(error))
            }
        }
        progress.addChild(refreshAppOperation.progress, withPendingUnitCount: 40)
        refreshAppOperation.addDependency(fetchProvisioningProfilesOperation)
        
        let operations = [fetchProvisioningProfilesOperation, refreshAppOperation]
        group.add(operations)
        self.run(operations, context: group.context)
        
        return progress
    }
    
    func finish(_ operation: AppOperation, result: Result<InstalledApp, Error>, group: RefreshGroup, progress: Progress?)
    {
        let result = result.mapError { (resultError) -> Error in
            guard let error = resultError as? ALTServerError else { return resultError }
            
            switch error.code
            {
            case .deviceNotFound, .lostConnection:
                if let server = group.context.server, server.isPreferred || server.isWiredConnection
                {
                    // Preferred server (or wired connection), so report errors normally.
                    return error
                }
                else
                {
                    // Not preferred server, so ignore these specific errors and throw serverNotFound instead.
                    return ConnectionError.serverNotFound
                }
                
            default: return error
            }
        }
        
        // Must remove before saving installedApp.
        if let currentProgress = self.progress(for: operation), currentProgress == progress
        {
            // Only remove progress if it hasn't been replaced by another one.
            self.set(nil, for: operation)
        }
        
        do
        {
            let installedApp = try result.get()
            group.set(.success(installedApp), forAppWithBundleIdentifier: installedApp.bundleIdentifier)
            
            if installedApp.bundleIdentifier == StoreApp.altstoreAppID
            {
                self.scheduleExpirationWarningLocalNotification(for: installedApp)
            }
            
            let event: AnalyticsManager.Event?
            
            switch operation
            {
            case .install: event = .installedApp(installedApp)
            case .refresh: event = .refreshedApp(installedApp)
            case .update where installedApp.bundleIdentifier == StoreApp.altstoreAppID:
                // AltStore quits before update finishes, so we've preemptively logged this update event.
                // In case AltStore doesn't quit, such as when update has a different bundle identifier,
                // make sure we don't log this update event a second time.
                event = nil
                
            case .update: event = .updatedApp(installedApp)
            }
            
            if let event = event
            {
                AnalyticsManager.shared.trackEvent(event)
            }
            
            do { try installedApp.managedObjectContext?.save() }
            catch { print("Error saving installed app.", error) }
        }
        catch
        {
            group.set(.failure(error), forAppWithBundleIdentifier: operation.bundleIdentifier)
        }
    }
    
    func scheduleExpirationWarningLocalNotification(for app: InstalledApp)
    {
        let notificationDate = app.expirationDate.addingTimeInterval(-1 * 60 * 60 * 24) // 24 hours before expiration.
        
        let timeIntervalUntilNotification = notificationDate.timeIntervalSinceNow
        guard timeIntervalUntilNotification > 0 else {
            // Crashes if we pass negative value to UNTimeIntervalNotificationTrigger initializer.
            return
        }
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: timeIntervalUntilNotification, repeats: false)
        
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("AltStore Expiring Soon", comment: "")
        content.body = NSLocalizedString("AltStore will expire in 24 hours. Open the app and refresh it to prevent it from expiring.", comment: "")
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: AppManager.expirationWarningNotificationID, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }
    
    func run(_ operations: [Foundation.Operation], context: OperationContext?, requiresSerialQueue: Bool = false)
    {
        for operation in operations
        {
            switch operation
            {
            case _ where requiresSerialQueue: fallthrough
            case is InstallAppOperation, is RefreshAppOperation:
                if let context = context, let previousOperation = self.serialOperationQueue.operations.last(where: { context.operations.contains($0) })
                {
                    // Ensure operations execute in the order they're added (in same context), since they may become ready at different points.
                    operation.addDependency(previousOperation)
                }
                
                self.serialOperationQueue.addOperation(operation)
                
            default:
                self.operationQueue.addOperation(operation)
            }
            
            context?.operations.add(operation)
        }
    }
    
    func progress(for operation: AppOperation) -> Progress?
    {
        switch operation
        {
        case .install, .update: return self.installationProgress[operation.bundleIdentifier]
        case .refresh: return self.refreshProgress[operation.bundleIdentifier]
        }
    }
    
    func set(_ progress: Progress?, for operation: AppOperation)
    {
        switch operation
        {
        case .install, .update: self.installationProgress[operation.bundleIdentifier] = progress
        case .refresh: self.refreshProgress[operation.bundleIdentifier] = progress
        }
    }
}
