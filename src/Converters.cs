using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;

namespace FieldPulseSIP;

// ── Value converters ──────────────────────────────────────────────────

public class StatusToAccentBrushConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        (value as string) switch
        {
            "PASS" => new SolidColorBrush(Color.FromRgb(26,  127,  55)),
            "FAIL" => new SolidColorBrush(Color.FromRgb(207,  34,  46)),
            "WARN" => new SolidColorBrush(Color.FromRgb(154, 103,   0)),
            "INFO" => new SolidColorBrush(Color.FromRgb(  5,  80, 174)),
            _      => new SolidColorBrush(Color.FromRgb( 87,  96, 106)),
        };
    public object ConvertBack(object value, Type t, object p, CultureInfo c) => throw new NotImplementedException();
}

public class StatusToBadgeBrushConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        (value as string) switch
        {
            "PASS" => new SolidColorBrush(Color.FromRgb(218, 251, 225)),
            "FAIL" => new SolidColorBrush(Color.FromRgb(255, 235, 233)),
            "WARN" => new SolidColorBrush(Color.FromRgb(255, 248, 197)),
            "INFO" => new SolidColorBrush(Color.FromRgb(221, 244, 255)),
            _      => new SolidColorBrush(Color.FromRgb(246, 248, 250)),
        };
    public object ConvertBack(object value, Type t, object p, CultureInfo c) => throw new NotImplementedException();
}

public class StatusToBadgeTextConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        (value as string) switch
        {
            "PASS" => "✓  PASS",
            "FAIL" => "✗  FAIL",
            "WARN" => "!  WARN",
            "INFO" => "i  INFO",
            _      => "·",
        };
    public object ConvertBack(object value, Type t, object p, CultureInfo c) => throw new NotImplementedException();
}

public class BoolToVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is true ? Visibility.Visible : Visibility.Collapsed;
    public object ConvertBack(object value, Type t, object p, CultureInfo c) => throw new NotImplementedException();
}

public class InverseBoolToVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        value is true ? Visibility.Collapsed : Visibility.Visible;
    public object ConvertBack(object value, Type t, object p, CultureInfo c) => throw new NotImplementedException();
}

// ── DataTemplateSelector ──────────────────────────────────────────────

public class ResultTemplateSelector : DataTemplateSelector
{
    public DataTemplate? SectionTemplate { get; set; }
    public DataTemplate? ResultTemplate  { get; set; }

    public override DataTemplate? SelectTemplate(object item, DependencyObject container)
    {
        if (item is CheckResult r)
            return r.IsSection ? SectionTemplate : ResultTemplate;
        return base.SelectTemplate(item, container);
    }
}

// ── Data models ───────────────────────────────────────────────────────

public class CheckResult
{
    // Regular result fields
    public string Category { get; set; } = "";
    public string Detail   { get; set; } = "";
    public string Status   { get; set; } = "INFO";   // PASS | FAIL | WARN | INFO

    // Section header fields
    public bool   IsSection    { get; set; } = false;
    public string SectionTitle { get; set; } = "";
}

public class PhoneEntry
{
    public string Brand        { get; set; } = "";
    public string PhoneModel   { get; set; } = "";
    public string MACAddress   { get; set; } = "";
    public string SerialNumber { get; set; } = "";
    public string Extension    { get; set; } = "";
    public string LineLabel    { get; set; } = "";
}

public class AttendeeEntry
{
    public string Name  { get; set; } = "";
    public string Email { get; set; } = "";
    public override string ToString() => $"{Name}  {Email}";
}

public class OnboardingData
{
    public string PhoneCountText { get; set; } = "";
    public int    PhoneCount     { get; set; }
    public string PhoneBrand     { get; set; } = "";
    public string PhoneModels    { get; set; } = "";
    public string ConfigType     { get; set; } = "";
    public string MacSerials     { get; set; } = "";
    public string ConfigNotes    { get; set; } = "";
    public string PreferredTime  { get; set; } = "";
    public string Attendees      { get; set; } = "";
    public bool   ConfirmedFormerProvider { get; set; }
    public bool   ConfirmedFactoryReset   { get; set; }
    public bool   ConfirmedFirmware       { get; set; }
    public List<PhoneEntry>? PhoneCSV     { get; set; }
}

public class CsvValidationResult
{
    public bool Valid                { get; set; }
    public List<PhoneEntry> Phones   { get; set; } = [];
    public List<string>     Errors   { get; set; } = [];
}
