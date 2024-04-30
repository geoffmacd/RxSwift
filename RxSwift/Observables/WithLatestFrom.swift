//
//  WithLatestFrom.swift
//  RxSwift
//
//  Created by Yury Korolev on 10/19/15.
//  Copyright © 2015 Krunoslav Zaher. All rights reserved.
//


/// Behaviors for the `withLatestFrom` operator family.
public enum WithLatestBehavior {
    /// Include only the immediate values emitted from the second observable. If the second observable is empty, deferred events will be ignored
    case immediate

    /// If empty, `withLatestFrom` will wait for the first value from the `second` observable and emit the combined values only when this happens.
    case deferred
}

extension ObservableType {

    /**
     Merges two observable sequences into one observable sequence by combining each element from self with the latest element from the second source, if any.
     
     - seealso: [combineLatest operator on reactivex.io](http://reactivex.io/documentation/operators/combinelatest.html)
     - note: Elements emitted by self before the second source has emitted any values will be omitted.
     
     - parameter second: Second observable source.
     - parameter behavior: Behavior to apply regarding the timing of immediate vs deferred events from the `second` observable
     - parameter resultSelector: Function to invoke for each element from the self combined with the latest element from the second source, if any.
     - returns: An observable sequence containing the result of combining each element of the self  with the latest element from the second source, if any, using the specified result selector function.
     */
    public func withLatestFrom<Source: ObservableConvertibleType, ResultType>(_ second: Source, behavior: WithLatestBehavior = .immediate, resultSelector: @escaping (Element, Source.Element) throws -> ResultType) -> Observable<ResultType> {
        WithLatestFrom(first: self.asObservable(), second: second.asObservable(), behavior: behavior, resultSelector: resultSelector)
    }

    /**
     Merges two observable sequences into one observable sequence by using latest element from the second sequence every time when `self` emits an element.

     - seealso: [combineLatest operator on reactivex.io](http://reactivex.io/documentation/operators/combinelatest.html)
     - note: Elements emitted by self before the second source has emitted any values will be omitted.

     - parameter second: Second observable source.
     - parameter behavior: Behavior to apply regarding the timing of immediate vs deferred events from the `second` observable
     - returns: An observable sequence containing the result of combining each element of the self  with the latest element from the second source, if any, using the specified result selector function.
     */
    public func withLatestFrom<Source: ObservableConvertibleType>(_ second: Source, behavior: WithLatestBehavior = .immediate) -> Observable<Source.Element> {
        WithLatestFrom(first: self.asObservable(), second: second.asObservable(), behavior: behavior, resultSelector: { $1 })
    }
}

final private class WithLatestFromSink<FirstType, SecondType, Observer: ObserverType>
    : Sink<Observer>
    , ObserverType
    , LockOwnerType
    , SynchronizedOnType {
    typealias ResultType = Observer.Element
    typealias Parent = WithLatestFrom<FirstType, SecondType, ResultType>
    typealias Element = FirstType
    
    private let parent: Parent
    private let behavior: WithLatestBehavior
    
    fileprivate var lock = RecursiveLock()
    fileprivate var latest: SecondType?
    fileprivate var awaitingLatest: FirstType?

    init(parent: Parent, observer: Observer, cancel: Cancelable, behavior: WithLatestBehavior) {
        self.parent = parent
        self.behavior = behavior
        
        super.init(observer: observer, cancel: cancel)
    }
    
    func run() -> Disposable {
        let sndSubscription = SingleAssignmentDisposable()
        let sndO = WithLatestFromSecond(parent: self, disposable: sndSubscription)
        
        sndSubscription.setDisposable(self.parent.second.subscribe(sndO))
        let fstSubscription = self.parent.first.subscribe(self)

        return Disposables.create(fstSubscription, sndSubscription)
    }

    func on(_ event: Event<Element>) {
        self.synchronizedOn(event)
    }

    func synchronized_on(_ event: Event<Element>) {
        switch event {
        case let .next(value):
            guard let latest = self.latest else {
                if behavior == .deferred {
                    awaitingLatest = value
                }
                return
            }
            do {
                let res = try self.parent.resultSelector(value, latest)
                
                self.forwardOn(.next(res))
            } catch let e {
                self.forwardOn(.error(e))
                self.dispose()
            }
        case .completed:
            self.forwardOn(.completed)
            self.dispose()
        case let .error(error):
            self.forwardOn(.error(error))
            self.dispose()
        }
    }
        
    func updateLatest(_ latest: SecondType?) {
        self.latest = latest
        
        if behavior == .deferred, let awaitingLatest, let latest {
            // we now have values from both observables and we were waiting to get the second
            do {
                let res = try self.parent.resultSelector(awaitingLatest, latest)
                self.forwardOn(.next(res))
            } catch let e {
                self.forwardOn(.error(e))
                self.dispose()
            }
        }
        awaitingLatest = nil
    }
}

final private class WithLatestFromSecond<FirstType, SecondType, Observer: ObserverType>
    : ObserverType
    , LockOwnerType
    , SynchronizedOnType {
    
    typealias ResultType = Observer.Element
    typealias Parent = WithLatestFromSink<FirstType, SecondType, Observer>
    typealias Element = SecondType
    
    private let parent: Parent
    private let disposable: Disposable

    var lock: RecursiveLock {
        self.parent.lock
    }

    init(parent: Parent, disposable: Disposable) {
        self.parent = parent
        self.disposable = disposable
    }
    
    func on(_ event: Event<Element>) {
        self.synchronizedOn(event)
    }

    func synchronized_on(_ event: Event<Element>) {
        switch event {
        case let .next(value):
            self.parent.updateLatest(value)
        case .completed:
            self.disposable.dispose()
        case let .error(error):
            self.parent.forwardOn(.error(error))
            self.parent.dispose()
        }
    }
}

final private class WithLatestFrom<FirstType, SecondType, ResultType>: Producer<ResultType> {
    typealias ResultSelector = (FirstType, SecondType) throws -> ResultType
    
    fileprivate let first: Observable<FirstType>
    fileprivate let second: Observable<SecondType>
    fileprivate let resultSelector: ResultSelector
    fileprivate let behavior: WithLatestBehavior

    init(first: Observable<FirstType>, second: Observable<SecondType>, behavior: WithLatestBehavior, resultSelector: @escaping ResultSelector) {
        self.first = first
        self.second = second
        self.resultSelector = resultSelector
        self.behavior = behavior
    }
    
    override func run<Observer: ObserverType>(_ observer: Observer, cancel: Cancelable) -> (sink: Disposable, subscription: Disposable) where Observer.Element == ResultType {
        let sink = WithLatestFromSink(parent: self, observer: observer, cancel: cancel, behavior: behavior)
        let subscription = sink.run()
        return (sink: sink, subscription: subscription)
    }
}
