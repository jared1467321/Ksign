import Foundation

@main struct NativeUploadProgressTests {
    static func main() {
        let mailbox = IDeviceInstallProgress()
        var deliveries = 0
        for index in 1...10_000 {
            if mailbox.submit(upload: Double(index) / 10_000) { deliveries += 1 }
        }
        precondition(deliveries == 1)
        precondition(mailbox.drain().upload == 1)
        precondition(!mailbox.submit(install: 0.5),
                     "A phase flush must not enqueue a second pending delivery")
        precondition(mailbox.drain(scheduled: true).install == 0.5)
        precondition(mailbox.submit(install: 1))
        precondition(mailbox.drain(finishing: true).install == 1)
        precondition(!mailbox.submit(upload: 0.2, install: 0.2))
        let stale = mailbox.drain(scheduled: true)
        precondition(stale.upload == nil && stale.install == nil,
                     "No stale progress may arrive after terminal delivery")
        print("Passed native upload UI coalescing, phase flush and terminal-delivery scenarios")
    }
}
