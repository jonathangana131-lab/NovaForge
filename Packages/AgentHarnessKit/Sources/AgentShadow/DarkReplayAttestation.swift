import AgentDomain
import AgentStore

/// Non-Codable replay authority. Only DarkReplayEngine can mint one, and every
/// canary use reruns the read-only replay before accepting its context/digests.
public struct DarkReplayAttestation: Sendable {
    public let runID: RunID
    public let acceptedReportSHA256: String
    public let acceptedLastOffset: AgentJournalOffset

    private let reader: any AgentEventReading
    private let acceptedReport: DarkReplayReport

    init(
        reader: any AgentEventReading,
        acceptedReport: DarkReplayReport
    ) {
        self.reader = reader
        self.acceptedReport = acceptedReport
        runID = acceptedReport.runID
        acceptedReportSHA256 = acceptedReport.digests.reportSHA256
        acceptedLastOffset = acceptedReport.lastOffset
    }

    func revalidatedReport() async throws -> DarkReplayReport {
        let current = try await DarkReplayEngine(reader: reader).replay(runID)
        guard current == acceptedReport else {
            throw DarkReplayError.staleReplayAttestation(runID: runID)
        }
        return current
    }
}
