import Carbon

@MainActor
final class GlobalHotKey {
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private let action: (UInt32) -> Void
    /// What is registered right now, so a rejected rebind can be rolled back onto it.
    private var assignments: [UInt32: HotKeyBinding]

    init(bindings: HotKeyBindings = .shared, action: @escaping (UInt32) -> Void) throws {
        self.action = action
        self.assignments = bindings.assignments
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                          nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
            guard result == noErr else { return result }
            let id = key.id
            MainActor.assumeIsolated {
                Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue().action(id)
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { throw AppError.hotKey(status) }
        do {
            try register(assignments)
        } catch {
            stop()
            throw error
        }
        bindings.adopt(self)
    }

    /// Swaps the registered combinations. The previous ones are restored before the error is
    /// thrown: this application is two keystrokes, so refusing a change is recoverable and
    /// leaving nothing registered is not.
    func apply(_ next: [UInt32: HotKeyBinding]) throws {
        guard next != assignments else { return }
        unregister()
        do {
            try register(next)
            assignments = next
        } catch {
            unregister()
            try? register(assignments)
            throw error
        }
    }

    /// Ids are registered in a fixed order so a partial failure leaves the same half
    /// registered every time, which is what the rollback above assumes.
    private func register(_ bindings: [UInt32: HotKeyBinding]) throws {
        for id in bindings.keys.sorted() {
            guard let binding = bindings[id] else { continue }
            var ref: EventHotKeyRef?
            let result = RegisterEventHotKey(binding.keyCode, binding.modifiers,
                                            EventHotKeyID(signature: 0x504F4C53, id: id), GetApplicationEventTarget(), 0, &ref)
            guard result == noErr, let ref else { throw AppError.hotKey(result) }
            refs.append(ref)
        }
    }

    private func unregister() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
    }

    func stop() {
        unregister()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}
