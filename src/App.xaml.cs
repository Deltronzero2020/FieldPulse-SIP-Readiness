using System.IO;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;

namespace FieldPulseSIP;

public partial class App : Application
{
    private static readonly string LogPath = Path.Combine(AppContext.BaseDirectory, "error.log");

    // Catch errors that occur during App construction / resource loading
    // (before OnStartup is reached)
    static App()
    {
        AppDomain.CurrentDomain.UnhandledException += (_, ex) =>
        {
            var exception = ex.ExceptionObject as Exception;
            WriteStructuredLog("FATAL", "AppDomain.UnhandledException", exception);
            MessageBox.Show(
                "Fatal error — see error.log next to the exe.\n\n" +
                (exception?.Message ?? ex.ExceptionObject?.ToString() ?? "Unknown"),
                "Fatal Error", MessageBoxButton.OK, MessageBoxImage.Error);
        };
    }

    protected override void OnStartup(StartupEventArgs e)
    {
        // Force software rendering — required in VMs without full DirectX support
        RenderOptions.ProcessRenderMode = RenderMode.SoftwareOnly;

        DispatcherUnhandledException += (_, ex) =>
        {
            WriteStructuredLog("ERROR", "Dispatcher.UnhandledException", ex.Exception);
            MessageBox.Show(
                "An error occurred — see error.log next to the exe.\n\n" + ex.Exception.Message,
                "Error", MessageBoxButton.OK, MessageBoxImage.Error);
            ex.Handled = true;
            Shutdown(1);
        };

        // Handle async task exceptions
        TaskScheduler.UnobservedTaskException += (_, ex) =>
        {
            WriteStructuredLog("ERROR", "TaskScheduler.UnobservedTaskException", ex.Exception);
            ex.SetObserved();
        };

        base.OnStartup(e);
    }

    /// <summary>
    /// Writes a structured log entry with timestamp, severity, source, and exception details.
    /// </summary>
    public static void WriteStructuredLog(string severity, string source, Exception? ex, string? additionalContext = null)
    {
        try
        {
            var entry = $"""
                ================================================================================
                Timestamp : {DateTime.UtcNow:O}
                Severity  : {severity}
                Source    : {source}
                Machine   : {Environment.MachineName}
                User      : {Environment.UserName}
                OS        : {Environment.OSVersion}
                {(additionalContext != null ? $"Context   : {additionalContext}\n" : "")}Exception : {ex?.GetType().FullName ?? "N/A"}
                Message   : {ex?.Message ?? "N/A"}

                Stack Trace:
                {ex?.ToString() ?? "N/A"}
                ================================================================================

                """;

            // Append to log file (don't overwrite previous entries)
            File.AppendAllText(LogPath, entry);
        }
        catch
        {
            // Last resort: try simple write
            try { File.WriteAllText(LogPath, ex?.ToString() ?? "Unknown error"); } catch { }
        }
    }

    /// <summary>
    /// Logs an operational message (non-exception) for audit purposes.
    /// </summary>
    public static void WriteAuditLog(string action, string details)
    {
        try
        {
            var entry = $"[{DateTime.UtcNow:O}] [{action}] {details}\n";
            File.AppendAllText(LogPath, entry);
        }
        catch { }
    }
}
