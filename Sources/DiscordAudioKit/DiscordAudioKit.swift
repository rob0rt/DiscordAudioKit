import DaveKit
import OpusKit
import Foundation

class DAKDaveSessionDelegate: DaveSessionDelegate {
    func sendMLSKeyPackage(keyPackage: Data) {
        
    }

    func readyForTransition(transitionId: UInt16) {
        
    }

    func sendMLSCommitWelcome(welcome: Data) {
        
    }

    func mlsInvalidCommitWelcome(transitionId: UInt16) {
        
    }
}

func foo() {
    let delegate = DAKDaveSessionDelegate()
    _ = DaveSessionManager(selfUserId: "", groupId: 123, delegate: delegate)
}