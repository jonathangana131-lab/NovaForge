import Foundation

// Xcode 26's Swift solver can time out while inferring the two compact
// Range.map expressions that seed traffic. These narrowly scoped overloads
// preserve the call sites and spawn math while making the closure result type
// explicit before the solver enters each initializer expression.
extension Range where Bound == Int {
    func map(_ transform: (Int) -> TrafficAgent) -> [TrafficAgent] {
        var result: [TrafficAgent] = []
        result.reserveCapacity(count)
        for index in self {
            result.append(transform(index))
        }
        return result
    }

    func map(_ transform: (Int) -> ScooterRiderAgent) -> [ScooterRiderAgent] {
        var result: [ScooterRiderAgent] = []
        result.reserveCapacity(count)
        for index in self {
            result.append(transform(index))
        }
        return result
    }
}
