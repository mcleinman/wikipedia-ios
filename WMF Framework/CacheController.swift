
import Foundation

enum CacheControllerError: Error {
    case atLeastOneItemFailedInFileWriter
    case failureToGenerateItemResult
}

public class CacheController {
    
    static let cacheURL: URL = {
        var url = FileManager.default.wmf_containerURL().appendingPathComponent("Permanent Cache", isDirectory: true)
        
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try url.setResourceValues(values)
        } catch {
            return url
        }
        
        return url
    }()
    
    //todo: Settings hook, logout don't sync hook, etc.
    public static var totalCacheSizeInBytes: Int64 {
        return FileManager.default.sizeOfDirectory(at: cacheURL)
    }
    
    static let backgroundCacheContext: NSManagedObjectContext? = {
        
        //create cacheURL directory
        do {
            try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true, attributes: nil)
        } catch let error {
            assertionFailure("Error creating permanent cache: \(error)")
            return nil
        }
        
        //create ManagedObjectModel based on Cache.momd
        guard let modelURL = Bundle.wmf.url(forResource: "Cache", withExtension: "momd"),
            let model = NSManagedObjectModel(contentsOf: modelURL) else {
                assertionFailure("Failure to create managed object model")
                return nil
        }

        //create persistent store coordinator / persistent store
        let dbURL = cacheURL.appendingPathComponent("Cache.sqlite", isDirectory: false)
        let persistentStoreCoordinator = NSPersistentStoreCoordinator(managedObjectModel: model)

        let options = [
            NSMigratePersistentStoresAutomaticallyOption: NSNumber(booleanLiteral: true),
            NSInferMappingModelAutomaticallyOption: NSNumber(booleanLiteral: true)
        ]

        do {
            try persistentStoreCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: dbURL, options: options)
        } catch {
            do {
                try FileManager.default.removeItem(at: dbURL)
            } catch {
                assertionFailure("Failure to remove old db file")
            }

            do {
                try persistentStoreCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: dbURL, options: options)
            } catch {
                assertionFailure("Failure to add persistent store to coordinator")
                return nil
            }
        }

        let cacheBackgroundContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        cacheBackgroundContext.persistentStoreCoordinator = persistentStoreCoordinator

        return cacheBackgroundContext
    }()
    
    public typealias ItemKey = String
    public typealias GroupKey = String
    public typealias UniqueKey = String //combo of item key + variant
    public typealias IndividualCompletionBlock = (FinalIndividualResult) -> Void
    public typealias GroupCompletionBlock = (FinalGroupResult) -> Void
    
    public struct ItemKeyAndVariant {
        let itemKey: CacheController.ItemKey
        let variant: String?
        
        init?(itemKey: CacheController.ItemKey?, variant: String?) {
            
            guard let itemKey = itemKey else {
                return nil
            }
            
            self.itemKey = itemKey
            self.variant = variant
        }
    }

    public enum FinalIndividualResult {
        case success(uniqueKey: CacheController.UniqueKey)
        case failure(error: Error)
    }
    
    public enum FinalGroupResult {
        case success(uniqueKeys: [CacheController.UniqueKey])
        case failure(error: Error)
    }
    
    let dbWriter: CacheDBWriting
    let fileWriter: CacheFileWriter
    private let cacheKeyGenerator: CacheKeyGenerating.Type
    let gatekeeper = CacheGatekeeper()
    
    init(dbWriter: CacheDBWriting, fileWriter: CacheFileWriter, cacheKeyGenerator: CacheKeyGenerating.Type) {
        self.dbWriter = dbWriter
        self.fileWriter = fileWriter
        self.cacheKeyGenerator = cacheKeyGenerator
    }

    public func add(url: URL, groupKey: GroupKey, individualCompletion: @escaping IndividualCompletionBlock, groupCompletion: @escaping GroupCompletionBlock) {
        
        if gatekeeper.shouldQueueAddCompletion(groupKey: groupKey) {
            gatekeeper.queueAddCompletion(groupKey: groupKey) {
                self.add(url: url, groupKey: groupKey, individualCompletion: individualCompletion, groupCompletion: groupCompletion)
                return
            }
        } else {
            gatekeeper.addCurrentlyAddingGroupKey(groupKey)
        }
        
        if gatekeeper.numberOfQueuedGroupCompletions(for: groupKey) > 0 {
            gatekeeper.queueGroupCompletion(groupKey: groupKey, groupCompletion: groupCompletion)
            return
        }
        
        gatekeeper.queueGroupCompletion(groupKey: groupKey, groupCompletion: groupCompletion)
        
        dbWriter.add(url: url, groupKey: groupKey) { [weak self] (result) in
            self?.finishDBAdd(groupKey: groupKey, individualCompletion: individualCompletion, groupCompletion: groupCompletion, result: result)
        }
    }
    
    public func cancelTasks(groupKey: String) {
        dbWriter.cancelTasks(for: groupKey)
        fileWriter.cancelTasks(for: groupKey)
    }
    
    func finishDBAdd(groupKey: GroupKey, individualCompletion: @escaping IndividualCompletionBlock, groupCompletion: @escaping GroupCompletionBlock, result: CacheDBWritingResultWithURLRequests) {
        
        let groupCompleteBlock = { (groupResult: FinalGroupResult) in
            self.gatekeeper.runAndRemoveGroupCompletions(groupKey: groupKey, groupResult: groupResult)
            self.gatekeeper.removeCurrentlyAddingGroupKey(groupKey)
            self.gatekeeper.runAndRemoveQueuedRemoves(groupKey: groupKey)
        }
        
        switch result {
            case .success(let urlRequests):
                
                var successfulKeys: [CacheController.UniqueKey] = []
                var failedKeys: [CacheController.UniqueKey] = []
                
                let group = DispatchGroup()
                for urlRequest in urlRequests {
                    
                    guard let url = urlRequest.url,
                        let itemKey =  urlRequest.allHTTPHeaderFields?[Session.Header.persistentCacheItemKey] else {
                            continue
                    }
                    
                    let variant = urlRequest.allHTTPHeaderFields?[Session.Header.persistentCacheItemVariant]
                    let uniqueKey = cacheKeyGenerator.uniqueFileNameForItemKey(itemKey, variant: variant)
                    
                    group.enter()
                    
                    if gatekeeper.numberOfQueuedIndividualCompletions(for: uniqueKey) > 0 {
                        defer {
                            group.leave()
                        }
                        gatekeeper.queueIndividualCompletion(uniqueKey: uniqueKey, individualCompletion: individualCompletion)
                        continue
                    }
                    
                    gatekeeper.queueIndividualCompletion(uniqueKey: uniqueKey, individualCompletion: individualCompletion)
                    
                    guard dbWriter.shouldDownloadVariant(itemKey: itemKey, variant: variant) else {
                        group.leave()
                        continue
                    }
                    
                    fileWriter.add(groupKey: groupKey, urlRequest: urlRequest) { [weak self] (result) in
                        
                        guard let self = self else {
                            return
                        }
                        
                        switch result {
                        case .success(let data, let mimeType):
                            
                            self.dbWriter.markDownloaded(urlRequest: urlRequest) { (result) in
                                
                                defer {
                                    group.leave()
                                }
                                
                                let individualResult: FinalIndividualResult
                                
                                switch result {
                                case .success:
                                    successfulKeys.append(uniqueKey)
                                    individualResult = FinalIndividualResult.success(uniqueKey: uniqueKey)
                                    
                                case .failure(let error):
                                    failedKeys.append(uniqueKey)
                                    individualResult = FinalIndividualResult.failure(error: error)
                                }
                                
                                self.gatekeeper.runAndRemoveIndividualCompletions(uniqueKey: uniqueKey, individualResult: individualResult)
                            }
                            
                            self.finishFileSave(data: data, mimeType: mimeType, uniqueKey: uniqueKey, url: url)
                            
                        case .failure(let error):
                            
                            defer {
                                group.leave()
                            }
                            
                            failedKeys.append(uniqueKey)
                            let individualResult = FinalIndividualResult.failure(error: error)
                            self.gatekeeper.runAndRemoveIndividualCompletions(uniqueKey: uniqueKey, individualResult: individualResult)
                        }
                    }
                    
                    group.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
                        
                        let groupResult = failedKeys.count > 0 ? FinalGroupResult.failure(error: CacheControllerError.atLeastOneItemFailedInFileWriter) : FinalGroupResult.success(uniqueKeys: successfulKeys)
                        
                        groupCompleteBlock(groupResult)
                    }
                }
            
            case .failure(let error):
                let groupResult = FinalGroupResult.failure(error: error)
                groupCompleteBlock(groupResult)
        }
    }
    
    func finishFileSave(data: Data, mimeType: String?, uniqueKey: CacheController.UniqueKey, url: URL) {
        //hook to allow subclasses to do any additional work with data
    }
    
    public func remove(groupKey: GroupKey, individualCompletion: @escaping IndividualCompletionBlock, groupCompletion: @escaping GroupCompletionBlock) {

        if gatekeeper.shouldQueueRemoveCompletion(groupKey: groupKey) {
            gatekeeper.queueRemoveCompletion(groupKey: groupKey) {
                self.remove(groupKey: groupKey, individualCompletion: individualCompletion, groupCompletion: groupCompletion)
                return
            }
        } else {
            gatekeeper.addCurrentlyRemovingGroupKey(groupKey)
        }
        
        if gatekeeper.numberOfQueuedGroupCompletions(for: groupKey) > 0 {
            gatekeeper.queueGroupCompletion(groupKey: groupKey, groupCompletion: groupCompletion)
            return
        }

        gatekeeper.queueGroupCompletion(groupKey: groupKey, groupCompletion: groupCompletion)

        cancelTasks(groupKey: groupKey)
        
        let groupCompleteBlock = { (groupResult: FinalGroupResult) in
            self.gatekeeper.runAndRemoveGroupCompletions(groupKey: groupKey, groupResult: groupResult)
            self.gatekeeper.removeCurrentlyRemovingGroupKey(groupKey)
            self.gatekeeper.runAndRemoveQueuedAdds(groupKey: groupKey)
        }

        dbWriter.fetchKeysToRemove(for: groupKey) { [weak self] (result) in
            
            guard let self = self else {
                return
            }
            
            switch result {
            case .success(let keys):
                
                var successfulKeys: [CacheController.UniqueKey] = []
                var failedKeys: [CacheController.UniqueKey] = []
                
                let group = DispatchGroup()
                for key in keys {
                    
                    let uniqueKey = self.cacheKeyGenerator.uniqueFileNameForItemKey(key.itemKey, variant: key.variant)
                    
                    group.enter()
                    
                    if self.gatekeeper.numberOfQueuedIndividualCompletions(for: uniqueKey) > 0 {
                        defer {
                            group.leave()
                        }
                        self.gatekeeper.queueIndividualCompletion(uniqueKey: uniqueKey, individualCompletion: individualCompletion)
                        continue
                    }
                    
                    self.gatekeeper.queueIndividualCompletion(uniqueKey: uniqueKey, individualCompletion: individualCompletion)
                    
                    self.fileWriter.remove(fileName: uniqueKey) { (result) in
                        
                        switch result {
                        case .success:
                            
                            self.dbWriter.remove(itemAndVariantKey: key) { (result) in
                                defer {
                                    group.leave()
                                }
                                
                                var individualResult: FinalIndividualResult
                                switch result {
                                case .success:
                                    successfulKeys.append(uniqueKey)
                                    individualResult = FinalIndividualResult.success(uniqueKey: uniqueKey)
                                case .failure(let error):
                                    failedKeys.append(uniqueKey)
                                    individualResult = FinalIndividualResult.failure(error: error)
                                }
                                
                                self.gatekeeper.runAndRemoveIndividualCompletions(uniqueKey: uniqueKey, individualResult: individualResult)
                            }
                            
                        case .failure(let error):
                            failedKeys.append(uniqueKey)
                            let individualResult = FinalIndividualResult.failure(error: error)
                            self.gatekeeper.runAndRemoveIndividualCompletions(uniqueKey: uniqueKey, individualResult: individualResult)
                            group.leave()
                        }
                    }
                }
                
                group.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
                    
                    if failedKeys.count == 0 {
                        
                        self.dbWriter.remove(groupKey: groupKey, completion: { (result) in
                            
                            var groupResult: FinalGroupResult
                            switch result {
                            case .success:
                                groupResult = FinalGroupResult.success(uniqueKeys: successfulKeys)
                                
                            case .failure(let error):
                                groupResult = FinalGroupResult.failure(error: error)
                            }
                            
                           groupCompleteBlock(groupResult)
                        })
                    } else {
                        let groupResult = FinalGroupResult.failure(error: CacheControllerError.atLeastOneItemFailedInFileWriter)
                        groupCompleteBlock(groupResult)
                    }
                }
                
            case .failure(let error):
                let groupResult = FinalGroupResult.failure(error: error)
                groupCompleteBlock(groupResult)
            }
        }
    }
    
    func responseFromPersistentCacheOrFallbackIfNeeded(request: URLRequest, cacheKeyGenerator: CacheKeyGenerating.Type) -> CachedURLResponse? {
        
        //1. first try pulling from URLCache
        if let response = URLCache.shared.cachedResponse(for: request) {
            return response
        }
        
        guard let url = request.url,
            let itemKey = request.allHTTPHeaderFields?[Session.Header.persistentCacheItemKey],
            let moc = CacheController.backgroundCacheContext else {
            return nil
        }
        
        let variant = request.allHTTPHeaderFields?[Session.Header.persistentCacheItemVariant]
        let itemTypeRaw = request.allHTTPHeaderFields?[Session.Header.persistentCacheItemType] ?? Session.Header.ItemType.article.rawValue
        let itemType = Session.Header.ItemType(rawValue: itemTypeRaw) ?? Session.Header.ItemType.article
        
        //2. else try pulling from Persistent Cache
        if let persistedCachedResponse = CacheProviderHelper.persistedCacheResponse(url: url, itemKey: itemKey, variant: variant, cacheKeyGenerator: cacheKeyGenerator) {
            return persistedCachedResponse
        //3. else try pulling a fallback from Persistent Cache
        } else if let fallbackCachedResponse = CacheProviderHelper.fallbackCacheResponse(url: url, itemKey: itemKey, variant: variant, itemType: itemType, cacheKeyGenerator: cacheKeyGenerator, moc: moc) {
            return fallbackCachedResponse
        }
        
        return nil
    }
}