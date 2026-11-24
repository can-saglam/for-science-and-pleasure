#if !APP_EXTENSION
import Foundation
import MetricKit

/// MetricKit's daily report (launch time, hangs, memory, battery) and its
/// crash and hang diagnostics, passed on to `metric_reports` (0055) so a
/// problem on someone's phone shows up somewhere. Signed out, they're
/// dropped; MetricKit doesn't deliver a payload twice, so a failed send is
/// lost, which is fine for numbers read in aggregate.
final class MetricReporter: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricReporter()

    func start() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        send(payloads.map { $0.jsonRepresentation() }, kind: "metrics")
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        send(payloads.map { $0.jsonRepresentation() }, kind: "diagnostics")
    }

    private func send(_ reports: [Data], kind: String) {
        guard !reports.isEmpty else { return }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        Task { @MainActor in
            guard SupabaseAuth.shared.signedIn, let token = try? await SupabaseAuth.shared.validToken() else { return }
            for data in reports {
                guard let payload = try? JSONSerialization.jsonObject(with: data) else { continue }
                var request = URLRequest(url: SupabaseAuth.baseURL.appending(path: "rest/v1/metric_reports"))
                request.httpMethod = "POST"
                request.setValue(SupabaseAuth.anonKey, forHTTPHeaderField: "apikey")
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
                var body: [String: Any] = ["kind": kind, "payload": payload]
                if let build { body["build"] = build }
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)
                _ = try? await URLSession.shared.data(for: request)
            }
        }
    }
}
#endif
