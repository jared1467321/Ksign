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

        let paused = IDeviceInstallProgress()
        for index in 1...10_000 {
            precondition(!paused.submit(upload: Double(index) / 10_000, allowsDelivery: false),
                         "Inactive transfers must retain samples without scheduling UI deliveries")
        }
        precondition(paused.drain(delivering: false).upload == nil)
        precondition(paused.drain().upload == 1, "Resume must deliver the latest retained sample")
        precondition(paused.submit(install: 0.25))
        precondition(paused.drain(scheduled: true, delivering: false).install == nil)
        precondition(!paused.submit(install: 0.75, allowsDelivery: false))
        precondition(paused.drain().install == 0.75)
        precondition(paused.submit(install: 0.9), "Expired inactive deliveries must release their slot")
        precondition(paused.drain().install == 0.9)
        precondition(!paused.submit(install: 0.95), "A foreground resume must preserve an outstanding timer")
        precondition(paused.drain(scheduled: true).install == 0.95)
        precondition(!paused.submit(install: 1, allowsDelivery: false))
        precondition(paused.drain(finishing: true, delivering: false).install == 1,
                     "Terminal status must flush the final value even while inactive")
        precondition(!paused.submit(install: 0.1))
        print("Passed native upload coalescing, inactive retention, foreground resume, phase flush and terminal delivery")
    }
}
