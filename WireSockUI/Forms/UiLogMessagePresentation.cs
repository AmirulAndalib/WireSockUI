using System;
using System.Globalization;
using System.Text;
using WireSockUI.Native;

namespace WireSockUI.Forms
{
    internal static class UiLogMessagePresentation
    {
        internal static bool ShouldDisplay(string message, WireguardBoosterExports.WgbLogLevel configuredLevel)
        {
            if (configuredLevel == WireguardBoosterExports.WgbLogLevel.All ||
                configuredLevel == WireguardBoosterExports.WgbLogLevel.Debug)
                return true;

            WireguardBoosterExports.WgbLogLevel messageLevel;
            if ((!TryExtractJsonStringProperty(message, "level", out var structuredLevel) ||
                 !TryMapLevel(structuredLevel, out messageLevel)) &&
                !TryClassify(FormatForDisplay(message), out messageLevel))
                return true;

            return Severity(messageLevel) <= Severity(configuredLevel);
        }

        internal static string FormatForDisplay(string message)
        {
            if (string.IsNullOrEmpty(message))
                return message ?? string.Empty;

            return TryExtractJsonStringProperty(message, "message", out var extractedMessage)
                ? extractedMessage
                : message;
        }

        private static bool TryClassify(string message, out WireguardBoosterExports.WgbLogLevel level)
        {
            var normalizedMessage = message?.TrimStart();

            if (StartsWith(normalizedMessage, "[ERROR]") || StartsWith(normalizedMessage, "ERROR:"))
            {
                level = WireguardBoosterExports.WgbLogLevel.Error;
                return true;
            }

            if (StartsWith(normalizedMessage, "[WARNING]") || StartsWith(normalizedMessage, "[WARN]") ||
                StartsWith(normalizedMessage, "WARNING:") || StartsWith(normalizedMessage, "WARN:"))
            {
                level = WireguardBoosterExports.WgbLogLevel.Warning;
                return true;
            }

            if (StartsWith(normalizedMessage, "[INFO]"))
            {
                level = WireguardBoosterExports.WgbLogLevel.Info;
                return true;
            }

            if (StartsWith(normalizedMessage, "[TRACE]") || StartsWith(normalizedMessage, "[DEBUG]") ||
                IsFilterTrafficTrace(normalizedMessage))
            {
                level = WireguardBoosterExports.WgbLogLevel.Debug;
                return true;
            }

            level = WireguardBoosterExports.WgbLogLevel.Error;
            return false;
        }

        private static int Severity(WireguardBoosterExports.WgbLogLevel level)
        {
            switch (level)
            {
                case WireguardBoosterExports.WgbLogLevel.Warning:
                    return 1;
                case WireguardBoosterExports.WgbLogLevel.Info:
                    return 2;
                case WireguardBoosterExports.WgbLogLevel.Debug:
                    return 3;
                case WireguardBoosterExports.WgbLogLevel.All:
                    return 4;
                default:
                    return 0;
            }
        }

        private static bool IsFilterTrafficTrace(string message)
        {
            const string filterPrefix = "[FILTER]:";
            if (!StartsWith(message, filterPrefix))
                return false;

            var trace = message.Substring(filterPrefix.Length).TrimStart();
            var hasPacketProtocol = StartsWith(trace, "UDP :") || StartsWith(trace, "TCP :") ||
                                    StartsWith(trace, "ICMP :") || StartsWith(trace, "ICMPV6 :");
            return hasPacketProtocol && trace.IndexOf(" -> ", StringComparison.Ordinal) > 0;
        }

        private static bool StartsWith(string message, string value)
        {
            return message?.StartsWith(value, StringComparison.OrdinalIgnoreCase) == true;
        }

        private static bool TryMapLevel(string value, out WireguardBoosterExports.WgbLogLevel level)
        {
            if (string.Equals(value, "error", StringComparison.OrdinalIgnoreCase))
                level = WireguardBoosterExports.WgbLogLevel.Error;
            else if (string.Equals(value, "warning", StringComparison.OrdinalIgnoreCase) ||
                     string.Equals(value, "warn", StringComparison.OrdinalIgnoreCase))
                level = WireguardBoosterExports.WgbLogLevel.Warning;
            else if (string.Equals(value, "info", StringComparison.OrdinalIgnoreCase))
                level = WireguardBoosterExports.WgbLogLevel.Info;
            else if (string.Equals(value, "debug", StringComparison.OrdinalIgnoreCase) ||
                     string.Equals(value, "trace", StringComparison.OrdinalIgnoreCase))
                level = WireguardBoosterExports.WgbLogLevel.Debug;
            else
            {
                level = WireguardBoosterExports.WgbLogLevel.Error;
                return false;
            }

            return true;
        }

        private static bool TryExtractJsonStringProperty(string value, string propertyName, out string propertyValue)
        {
            propertyValue = null;
            if (string.IsNullOrEmpty(value) || string.IsNullOrEmpty(propertyName))
                return false;

            var quotedPropertyName = $"\"{propertyName}\"";
            var propertyIndex = value.IndexOf(quotedPropertyName, StringComparison.OrdinalIgnoreCase);
            if (propertyIndex < 0)
                return false;

            var index = propertyIndex + quotedPropertyName.Length;
            SkipWhitespace(value, ref index);
            if (index >= value.Length || value[index++] != ':')
                return false;

            SkipWhitespace(value, ref index);
            if (index >= value.Length || value[index++] != '"')
                return false;

            var builder = new StringBuilder();
            while (index < value.Length)
            {
                var character = value[index++];
                if (character == '"')
                {
                    propertyValue = builder.ToString();
                    return true;
                }

                if (character != '\\')
                {
                    builder.Append(character);
                    continue;
                }

                if (index >= value.Length)
                    return false;

                var escaped = value[index++];
                switch (escaped)
                {
                    case '"':
                    case '\\':
                    case '/':
                        builder.Append(escaped);
                        break;
                    case 'b':
                        builder.Append('\b');
                        break;
                    case 'f':
                        builder.Append('\f');
                        break;
                    case 'n':
                        builder.Append('\n');
                        break;
                    case 'r':
                        builder.Append('\r');
                        break;
                    case 't':
                        builder.Append('\t');
                        break;
                    case 'u':
                        if (!TryReadUnicodeEscape(value, ref index, out var unicodeCharacter))
                            return false;
                        builder.Append(unicodeCharacter);
                        break;
                    default:
                        return false;
                }
            }

            return false;
        }

        private static bool TryReadUnicodeEscape(string value, ref int index, out char character)
        {
            character = default;
            if (index + 4 > value.Length ||
                !ushort.TryParse(value.Substring(index, 4), NumberStyles.HexNumber,
                    CultureInfo.InvariantCulture, out var codePoint))
                return false;

            index += 4;
            character = (char)codePoint;
            return true;
        }

        private static void SkipWhitespace(string value, ref int index)
        {
            while (index < value.Length && char.IsWhiteSpace(value[index]))
                index++;
        }
    }
}
