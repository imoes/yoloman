using System.Text.Json;

namespace AgenticMcp.Agent.Windows;

/// <summary>
/// Reading PowerShell's JSON without repeating the same four TryGetProperty dances in every module.
///
/// <para>Every value here is OPTIONAL BY DESIGN, and that is the point rather than laziness: PowerShell's
/// ConvertTo-Json omits a property whose value is $null, turns a one-element collection into a bare object
/// instead of an array, and spells a property exactly as the cmdlet did. A module that indexed into that
/// directly would throw on a host where one account happens to have no description — which is how a read of
/// 40 accounts fails because of the 37th. So an absent value reads as empty, an absent array as empty, and the
/// module decides what that means.</para>
/// </summary>
internal static class JsonReads
{
    // The one-object-instead-of-an-array case that ConvertTo-Json produces for a single item is already
    // handled where the JSON is parsed (WindowsPowerShellBridge.RunJson fills Items either way), so it is
    // deliberately NOT handled a second time here: two places normalising the same thing is how they end up
    // disagreeing.

    /// <summary>A property as a string: "" when absent, null or of another kind. Numbers and booleans are
    /// rendered rather than refused, since a caller asking for a string wants what the host said.</summary>
    internal static string String(this JsonElement element, string name) =>
        element.ValueKind == JsonValueKind.Object && element.TryGetProperty(name, out var value)
            ? value.ValueKind switch
            {
                JsonValueKind.String => value.GetString() ?? "",
                JsonValueKind.Null or JsonValueKind.Undefined => "",
                _ => value.ToString(),
            }
            : "";

    /// <summary>A property as a bool. Absent is FALSE and not null: every current caller asks about a flag
    /// Windows always answers (Enabled), and a nullable here would push a three-valued check into each of
    /// them for a case that does not occur. A property that can genuinely be unknown should be read as a
    /// string instead.</summary>
    internal static bool Bool(this JsonElement element, string name) =>
        element.ValueKind == JsonValueKind.Object && element.TryGetProperty(name, out var value)
        && value.ValueKind == JsonValueKind.True;

    /// <summary>A property as a number of bytes: null when absent or not a number. NULLABLE on purpose —
    /// "this partition has no free-space figure" and "it has zero bytes free" are different statements, and a
    /// storage view that showed the first as the second would report a full disk that is not.</summary>
    internal static long? Long(this JsonElement element, string name) =>
        element.ValueKind == JsonValueKind.Object && element.TryGetProperty(name, out var value)
        && value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var number)
            ? number
            : null;

    /// <summary>A property as a list of strings. A bare scalar counts as a one-element list, for the same
    /// ConvertTo-Json reason as above: a group with one member arrives as a string, not an array.</summary>
    internal static List<string> StringArray(this JsonElement element, string name)
    {
        var list = new List<string>();
        if (element.ValueKind != JsonValueKind.Object || !element.TryGetProperty(name, out var value))
        {
            return list;
        }
        switch (value.ValueKind)
        {
            case JsonValueKind.Array:
                foreach (var item in value.EnumerateArray())
                {
                    var text = item.ValueKind == JsonValueKind.String ? item.GetString() : item.ToString();
                    if (!string.IsNullOrEmpty(text))
                    {
                        list.Add(text);
                    }
                }
                break;
            case JsonValueKind.String:
                var single = value.GetString();
                if (!string.IsNullOrEmpty(single))
                {
                    list.Add(single);
                }
                break;
        }
        return list;
    }
}
