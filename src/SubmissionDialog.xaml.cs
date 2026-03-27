using System.Collections.ObjectModel;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Microsoft.Win32;

namespace FieldPulseSIP;

public partial class SubmissionDialog : Window
{
    // ── Result property (set on successful submit) ─────────────────
    public OnboardingData? ResultData { get; private set; }

    // ── Backing collections ────────────────────────────────────────
    private readonly ObservableCollection<AttendeeEntry> _attendees = [];
    private readonly ObservableCollection<PhoneEntry>    _macEntries = [];
    private readonly ObservableCollection<string>        _models = [];

    // ── CSV state ─────────────────────────────────────────────────
    private List<PhoneEntry>? _csvPhones;

    // ── Validation regex ──────────────────────────────────────────
    // RFC 5322 simplified: local-part @ domain with 2+ char TLD
    private static readonly Regex EmailRegex =
        new(@"^[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$",
            RegexOptions.Compiled);

    private static readonly Regex FullMacRegex =
        new(@"^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$", RegexOptions.Compiled);

    private static readonly Regex MacRegex =
        new(@"^([0-9A-Fa-f]{2}[:\-]){5}[0-9A-Fa-f]{2}$|^[0-9A-Fa-f]{12}$",
            RegexOptions.Compiled);

    // ── Constructor ───────────────────────────────────────────────
    public SubmissionDialog()
    {
        InitializeComponent();
        lvAttendees.ItemsSource = _attendees;
        lvMacs.ItemsSource      = _macEntries;
        lvModels.ItemsSource    = _models;
    }

    // ─────────────────────────────────────────────────────────────
    // Brand helpers
    // ─────────────────────────────────────────────────────────────

    /// <summary>Returns every checked brand name, including the Other free-text entry.</summary>
    private List<string> GetSelectedBrands()
    {
        var brands = new List<string>();

        (CheckBox chk, string label)[] pairs =
        [
            (chkBrandYealink,     "Yealink"),
            (chkBrandPolycom,     "Polycom / Poly"),
            (chkBrandCisco,       "Cisco"),
            (chkBrandGrandstream, "Grandstream"),
            (chkBrandFanvil,      "Fanvil"),
            (chkBrandSnom,        "Snom"),
            (chkBrandObihai,      "Obihai"),
            (chkBrandAvaya,       "Avaya"),
            (chkBrandMitel,       "Mitel"),
        ];

        foreach (var (chk, label) in pairs)
            if (chk.IsChecked == true) brands.Add(label);

        if (chkBrandOther.IsChecked == true)
        {
            string other = txtBrandOther.Text.Trim();
            if (!string.IsNullOrEmpty(other)) brands.Add(other);
        }

        return brands;
    }

    // ─────────────────────────────────────────────────────────────
    // Model management
    // ─────────────────────────────────────────────────────────────

    private void TxtModelInput_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Return || e.Key == Key.Enter) TryAddModel();
    }

    private void BtnAddModel_Click(object sender, RoutedEventArgs e) => TryAddModel();

    private void TryAddModel()
    {
        errModel.Visibility = Visibility.Collapsed;

        string model = txtModelInput.Text.Trim();
        if (string.IsNullOrEmpty(model))
        {
            errModel.Text = "Enter a model name.";
            errModel.Visibility = Visibility.Visible;
            txtModelInput.Focus();
            return;
        }

        if (_models.Any(m => m.Equals(model, StringComparison.OrdinalIgnoreCase)))
        {
            errModel.Text = $"'{model}' is already in the list.";
            errModel.Visibility = Visibility.Visible;
            return;
        }

        if (_models.Count >= 20)
        {
            errModel.Text = "Maximum 20 models reached.";
            errModel.Visibility = Visibility.Visible;
            return;
        }

        _models.Add(model);
        txtModelInput.Clear();
        txtModelInput.Focus();
    }

    private void BtnRemoveModel_Click(object sender, RoutedEventArgs e)
    {
        if (lvModels.SelectedItem is string model)
            _models.Remove(model);
    }

    // ─────────────────────────────────────────────────────────────
    // MAC address entry
    // ─────────────────────────────────────────────────────────────

    private bool _formattingMac;

    private void TxtMacInput_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (_formattingMac) return;
        _formattingMac = true;

        string raw = Regex.Replace(txtMacInput.Text, @"[^0-9A-Fa-f]", "");
        if (raw.Length > 12) raw = raw[..12];

        var sb = new StringBuilder();
        for (int i = 0; i < raw.Length; i++)
        {
            if (i > 0 && i % 2 == 0) sb.Append(':');
            sb.Append(char.ToUpper(raw[i]));
        }
        string formatted = sb.ToString();

        txtMacInput.Text       = formatted;
        txtMacInput.CaretIndex = formatted.Length;

        _formattingMac = false;
    }

    private void TxtMacInput_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Return || e.Key == Key.Enter) TryAddMac();
    }

    private void BtnAddMac_Click(object sender, RoutedEventArgs e) => TryAddMac();

    private void TryAddMac()
    {
        errMac.Visibility = Visibility.Collapsed;

        string mac    = txtMacInput.Text.Trim();
        string serial = txtMacSerial.Text.Trim();
        string label  = txtMacLabel.Text.Trim();

        if (string.IsNullOrEmpty(mac))
        {
            errMac.Text = "MAC address is required.";
            errMac.Visibility = Visibility.Visible;
            txtMacInput.Focus();
            return;
        }

        if (!FullMacRegex.IsMatch(mac))
        {
            errMac.Text = $"'{mac}' is not a valid MAC address (need 12 hex digits, e.g. AA:BB:CC:DD:EE:FF).";
            errMac.Visibility = Visibility.Visible;
            txtMacInput.Focus();
            return;
        }

        if (_macEntries.Any(m => m.MACAddress.Equals(mac, StringComparison.OrdinalIgnoreCase)))
        {
            errMac.Text = $"{mac} is already in the list.";
            errMac.Visibility = Visibility.Visible;
            return;
        }

        _macEntries.Add(new PhoneEntry { MACAddress = mac, SerialNumber = serial, LineLabel = label });
        txtMacInput.Clear();
        txtMacSerial.Clear();
        txtMacLabel.Clear();
        txtMacInput.Focus();
    }

    private void BtnRemoveMac_Click(object sender, RoutedEventArgs e)
    {
        if (lvMacs.SelectedItem is PhoneEntry entry)
            _macEntries.Remove(entry);
    }

    // ─────────────────────────────────────────────────────────────
    // Attendee management
    // ─────────────────────────────────────────────────────────────

    private void BtnAddAttendee_Click(object sender, RoutedEventArgs e) => TryAddAttendee();

    private void TxtAttendeeEmail_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Return || e.Key == Key.Enter) TryAddAttendee();
    }

    private void TryAddAttendee()
    {
        errAttendee.Visibility = Visibility.Collapsed;

        string name  = txtAttendeeName.Text.Trim();
        string email = txtAttendeeEmail.Text.Trim();

        if (string.IsNullOrEmpty(name))
        {
            ShowAttendeeError("Name is required.");
            txtAttendeeName.Focus();
            return;
        }
        if (string.IsNullOrEmpty(email) || !EmailRegex.IsMatch(email))
        {
            ShowAttendeeError("A valid email address is required.");
            txtAttendeeEmail.Focus();
            return;
        }
        if (_attendees.Any(a => a.Email.Equals(email, StringComparison.OrdinalIgnoreCase)))
        {
            ShowAttendeeError($"{email} is already in the list.");
            return;
        }

        _attendees.Add(new AttendeeEntry { Name = name, Email = email });
        txtAttendeeName.Clear();
        txtAttendeeEmail.Clear();
        txtAttendeeName.Focus();
        errNoAttendees.Visibility = Visibility.Collapsed;
    }

    private void ShowAttendeeError(string msg)
    {
        errAttendee.Text = msg;
        errAttendee.Visibility = Visibility.Visible;
    }

    private void BtnRemoveAttendee_Click(object sender, RoutedEventArgs e)
    {
        if (lvAttendees.SelectedItem is AttendeeEntry entry)
            _attendees.Remove(entry);
    }

    // ─────────────────────────────────────────────────────────────
    // CSV template download
    // ─────────────────────────────────────────────────────────────

    private void BtnDownloadTemplate_Click(object sender, RoutedEventArgs e)
    {
        var dlg = new SaveFileDialog
        {
            Title      = "Save CSV Template",
            FileName   = "FieldPulse_Phone_Template.csv",
            Filter     = "CSV files (*.csv)|*.csv",
            DefaultExt = ".csv"
        };
        if (dlg.ShowDialog() != true) return;

        string header  = "Brand,PhoneModel,MACAddress,SerialNumber,Extension,LineLabel\r\n";
        string example = "Yealink,SIP-T46S,80:5E:C0:54:0F:14,ABC123456,101,Front Desk\r\n";

        try
        {
            File.WriteAllText(dlg.FileName, header + example, new UTF8Encoding(true));
            lblCsvStatus.Text = $"Template saved: {Path.GetFileName(dlg.FileName)}";
        }
        catch (Exception ex)
        {
            ShowError($"Could not save template: {ex.Message}");
        }
    }

    // ─────────────────────────────────────────────────────────────
    // CSV upload & validation
    // ─────────────────────────────────────────────────────────────

    private void BtnUploadCsv_Click(object sender, RoutedEventArgs e)
    {
        var dlg = new OpenFileDialog
        {
            Title  = "Select Phone CSV",
            Filter = "CSV files (*.csv)|*.csv"
        };
        if (dlg.ShowDialog() != true) return;

        var result = ValidateCsv(dlg.FileName);

        if (!result.Valid)
        {
            lblCsvStatus.Foreground = System.Windows.Media.Brushes.Red;
            lblCsvStatus.Text = $"CSV rejected:\n\u2022 {string.Join("\n\u2022 ", result.Errors)}";
            _csvPhones = null;
            return;
        }

        _csvPhones = result.Phones;

        // Auto-fill phone count only — MAC list and model/brand entries are independent
        txtPhoneCount.Text = _csvPhones.Count.ToString();

        lblCsvStatus.Foreground = new System.Windows.Media.SolidColorBrush(
            System.Windows.Media.Color.FromRgb(26, 127, 55));
        lblCsvStatus.Text = $"\u2713  {_csvPhones.Count} phone(s) loaded from {Path.GetFileName(dlg.FileName)}";
    }

    // ─────────────────────────────────────────────────────────────
    // CSV validation
    // ─────────────────────────────────────────────────────────────

    private static CsvValidationResult ValidateCsv(string path)
    {
        var result = new CsvValidationResult();

        var info = new FileInfo(path);
        if (info.Length > 512_000)
        {
            result.Errors.Add("File exceeds 500 KB limit.");
            return result;
        }

        string[] lines;
        try { lines = File.ReadAllLines(path, Encoding.UTF8); }
        catch (Exception ex)
        {
            result.Errors.Add($"Cannot read file: {ex.Message}");
            return result;
        }

        string raw = string.Concat(lines);
        if (raw.Contains('\0'))
        {
            result.Errors.Add("File contains null bytes — not a valid CSV.");
            return result;
        }

        if (lines.Length < 2)
        {
            result.Errors.Add("CSV has no data rows.");
            return result;
        }

        string[] expectedHeaders = ["Brand", "PhoneModel", "MACAddress", "SerialNumber", "Extension", "LineLabel"];
        string[] headers = lines[0].Split(',');
        if (headers.Length < 2 ||
            !headers[0].Trim().Equals("Brand", StringComparison.OrdinalIgnoreCase))
        {
            result.Errors.Add("Invalid header. Expected: Brand,PhoneModel,MACAddress,SerialNumber,Extension,LineLabel");
            return result;
        }

        if (lines.Length > 502)
        {
            result.Errors.Add("CSV exceeds 500 rows.");
            return result;
        }

        var phones = new List<PhoneEntry>();

        for (int i = 1; i < lines.Length; i++)
        {
            string line = lines[i].Trim();
            if (string.IsNullOrEmpty(line)) continue;

            string[] cols = SplitCsvLine(line);

            for (int c = 0; c < cols.Length; c++)
            {
                string val   = cols[c].Trim();
                string field = c < expectedHeaders.Length ? expectedHeaders[c] : $"col{c}";
                string? err  = CheckFieldSecurity(val, field, i + 1);
                if (err != null) result.Errors.Add(err);
            }

            if (result.Errors.Count > 0) return result;

            var entry = new PhoneEntry
            {
                Brand        = cols.ElementAtOrDefault(0)?.Trim() ?? "",
                PhoneModel   = cols.ElementAtOrDefault(1)?.Trim() ?? "",
                MACAddress   = cols.ElementAtOrDefault(2)?.Trim() ?? "",
                SerialNumber = cols.ElementAtOrDefault(3)?.Trim() ?? "",
                Extension    = cols.ElementAtOrDefault(4)?.Trim() ?? "",
                LineLabel    = cols.ElementAtOrDefault(5)?.Trim() ?? "",
            };

            if (!string.IsNullOrEmpty(entry.MACAddress) && !MacRegex.IsMatch(entry.MACAddress))
                result.Errors.Add($"Row {i + 1}: Invalid MAC address format '{entry.MACAddress}'.");

            if (!string.IsNullOrEmpty(entry.Extension) &&
                !Regex.IsMatch(entry.Extension, @"^\d{1,10}$"))
                result.Errors.Add($"Row {i + 1}: Extension must be numeric (got '{entry.Extension}').");

            if (result.Errors.Count > 0) return result;

            phones.Add(entry);
        }

        if (phones.Count == 0)
        {
            result.Errors.Add("CSV has no valid data rows.");
            return result;
        }

        result.Valid  = true;
        result.Phones = phones;
        return result;
    }

    // ─────────────────────────────────────────────────────────────
    // Security checks for a single CSV field value
    // ─────────────────────────────────────────────────────────────

    private static string? CheckFieldSecurity(string val, string field, int rowNum)
    {
        if (string.IsNullOrEmpty(val)) return null;

        if (Regex.IsMatch(val, @"^[=+\-@|]"))
            return $"Row {rowNum} [{field}]: Formula injection detected (starts with {val[0]}).";

        if (Regex.IsMatch(val, @"(?i)^cmd\s*\|"))
            return $"Row {rowNum} [{field}]: DDE injection detected.";

        if (Regex.IsMatch(val, @"<\s*(script|iframe|img|svg|object|embed|link|meta|form|input|button|a)\b",
                RegexOptions.IgnoreCase))
            return $"Row {rowNum} [{field}]: HTML injection detected.";

        if (Regex.IsMatch(val, @"(?i)(javascript|vbscript)\s*:"))
            return $"Row {rowNum} [{field}]: Script URI injection detected.";

        if (val.IndexOfAny(['\r', '\n']) >= 0)
            return $"Row {rowNum} [{field}]: CRLF injection detected.";

        if (Regex.IsMatch(val, @"[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]"))
            return $"Row {rowNum} [{field}]: Control character detected.";

        return null;
    }

    // ─────────────────────────────────────────────────────────────
    // Naive CSV field splitter (handles quoted fields)
    // ─────────────────────────────────────────────────────────────

    private static string[] SplitCsvLine(string line)
    {
        var fields = new List<string>();
        bool inQuotes = false;
        var current = new StringBuilder();

        foreach (char ch in line)
        {
            if (ch == '"')
                inQuotes = !inQuotes;
            else if (ch == ',' && !inQuotes)
            {
                fields.Add(current.ToString());
                current.Clear();
            }
            else
                current.Append(ch);
        }
        fields.Add(current.ToString());
        return [.. fields];
    }

    // ─────────────────────────────────────────────────────────────
    // Submit
    // ─────────────────────────────────────────────────────────────

    private void BtnSubmit_Click(object sender, RoutedEventArgs e)
    {
        ClearErrors();

        var errors = new List<string>();

        // Number of phones
        string phoneCountText = txtPhoneCount.Text.Trim();
        if (string.IsNullOrEmpty(phoneCountText))
        {
            ShowFieldError(errPhoneCount, "Required.");
            errors.Add("Number of phones is required.");
        }

        // Brand(s)
        var selectedBrands = GetSelectedBrands();
        if (selectedBrands.Count == 0)
        {
            ShowFieldError(errPhoneBrand, "Select at least one brand.");
            errors.Add("Phone brand is required.");
        }
        else if (chkBrandOther.IsChecked == true && string.IsNullOrWhiteSpace(txtBrandOther.Text))
        {
            ShowFieldError(errPhoneBrand, "Enter a brand name for 'Other'.");
            errors.Add("Other brand name is required when 'Other' is checked.");
        }

        // Config type
        string configType = GetComboText(cmbConfigType);
        if (string.IsNullOrEmpty(configType))
        {
            ShowFieldError(errConfigType, "Required.");
            errors.Add("Configuration type is required.");
        }

        // Preferred time
        string preferredTime = GetComboText(cmbPreferredTime);
        if (string.IsNullOrEmpty(preferredTime))
        {
            ShowFieldError(errPreferredTime, "Required.");
            errors.Add("Preferred time is required.");
        }

        // Attendees
        if (_attendees.Count == 0)
        {
            errNoAttendees.Visibility = Visibility.Visible;
            errors.Add("At least one attendee is required.");
        }

        // Confirmations — either new phones OR provider-switch items must be checked
        bool isNewPhones     = chkNewPhones.IsChecked == true;
        bool providerChecked = chkFormerProvider.IsChecked == true &&
                               chkPhonesReleased.IsChecked == true &&
                               chkProvisioningPasswords.IsChecked == true;
        bool prepChecked     = chkFactoryReset.IsChecked == true &&
                               chkFirmware.IsChecked == true;

        if (!isNewPhones && !providerChecked)
        {
            errConfirmations.Visibility = Visibility.Visible;
            errConfirmations.Text = "Please check the 'new phones' box, or confirm all three items about switching from your old provider.";
            errors.Add("Provider switch confirmations are required.");
        }
        if (!prepChecked)
        {
            errConfirmations.Visibility = Visibility.Visible;
            errConfirmations.Text = "Please confirm the phone preparation items (factory reset and software update).";
            errors.Add("Phone preparation confirmations are required.");
        }

        if (errors.Count > 0)
        {
            ShowError($"Please fix {errors.Count} issue(s) before submitting.");
            return;
        }

        // Parse phone count (first integer found, or 0)
        int phoneCount = 0;
        var m = Regex.Match(phoneCountText, @"\d+");
        if (m.Success) phoneCount = int.Parse(m.Value);

        // Build OnboardingData
        ResultData = new OnboardingData
        {
            PhoneCountText          = phoneCountText,
            PhoneCount              = phoneCount,
            PhoneBrand              = string.Join(", ", selectedBrands),
            PhoneModels             = _models.Count > 0
                                          ? string.Join(", ", _models)
                                          : "",
            ConfigType              = configType,
            MacSerials              = _macEntries.Count > 0
                                          ? string.Join("; ", _macEntries.Select(me =>
                                              $"{me.MACAddress}" +
                                              (string.IsNullOrEmpty(me.SerialNumber) ? "" : $" / {me.SerialNumber}") +
                                              (string.IsNullOrEmpty(me.LineLabel)    ? "" : $" ({me.LineLabel})")))
                                          : "",
            ConfigNotes             = txtConfigNotes.Text.Trim(),
            PreferredTime           = preferredTime,
            Attendees               = string.Join("; ", _attendees.Select(a => $"{a.Name} <{a.Email}>")),
            ConfirmedNewPhones              = chkNewPhones.IsChecked == true,
            ConfirmedFormerProvider         = chkFormerProvider.IsChecked == true,
            ConfirmedPhonesReleased         = chkPhonesReleased.IsChecked == true,
            ConfirmedProvisioningPasswords  = chkProvisioningPasswords.IsChecked == true,
            ConfirmedFactoryReset           = chkFactoryReset.IsChecked == true,
            ConfirmedFirmware               = chkFirmware.IsChecked == true,
            PhoneCSV                = _csvPhones,
        };

        DialogResult = true;
    }

    // ─────────────────────────────────────────────────────────────
    // Cancel
    // ─────────────────────────────────────────────────────────────

    private void BtnCancel_Click(object sender, RoutedEventArgs e) => DialogResult = false;

    // ─────────────────────────────────────────────────────────────
    // Error helpers
    // ─────────────────────────────────────────────────────────────

    private static void ShowFieldError(TextBlock tb, string msg)
    {
        tb.Text = msg;
        tb.Visibility = Visibility.Visible;
    }

    private void ShowError(string msg)
    {
        lblGlobalError.Text = msg;
        pnlGlobalError.Visibility = Visibility.Visible;
    }

    private void ClearErrors()
    {
        foreach (var tb in new[] { errPhoneCount, errPhoneBrand, errConfigType, errPreferredTime, errModel, errMac })
            tb.Visibility = Visibility.Collapsed;

        errAttendee.Visibility      = Visibility.Collapsed;
        errNoAttendees.Visibility   = Visibility.Collapsed;
        errConfirmations.Visibility = Visibility.Collapsed;
        pnlGlobalError.Visibility   = Visibility.Collapsed;
    }

    // ─────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────

    private static string GetComboText(ComboBox cmb)
    {
        string text = cmb.Text?.Trim() ?? "";
        if (string.IsNullOrEmpty(text) && cmb.SelectedItem is ComboBoxItem item)
            text = item.Content?.ToString()?.Trim() ?? "";
        return text;
    }
}
