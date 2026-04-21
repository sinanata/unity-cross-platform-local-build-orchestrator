// Headless CLI entry points for Unity batchmode.
//
// Drop this file into your project's Assets/Editor folder (Unity will pick it up
// as an editor script). The Build-All.ps1 / build_mac.sh orchestrator invokes it
// via -executeMethod. You shouldn't normally call these methods by hand.
//
// Invocation template (orchestrator does this for you):
//   Unity -batchmode -quit -projectPath <root>
//         -buildTarget <Win64|Android|iOS|OSXUniversal>
//         -executeMethod BuildOrchestrator.Cli.BuildCli.<Entry>
//         -cliBuildPath <absolute path>
//         -cliKeystorePath <path>  -cliKeystorePass <pw>
//         -cliKeyaliasName <alias> -cliKeyaliasPass <pw>
//         -cliIosAppend true|false
//         -cliBumpKind patch|minor|major|none
//         -cliReportPath <json output path>
//         -logFile <log path>
//
// Entry points:
//   Windows, MacOS, iOS, Android, BumpVersion, PrintVersion
//
// Scenes are pulled from EditorBuildSettings — whatever you configured in
// File → Build Settings. If that list is empty, this script throws.
//
// Part of https://github.com/sinanata/unity-cross-platform-local-build-orchestrator
// Originally built for https://leapoflegends.com

using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using UnityEditor;
using UnityEditor.Build;
using UnityEditor.Build.Reporting;
using UnityEngine;

namespace BuildOrchestrator.Cli
{
    public static class BuildCli
    {
        private const string LogPrefix = "[BuildCli]";

        // Defines applied per platform. Tweak these if your project uses
        // different conditional compilation symbols — e.g. remove STEAMWORKS_NET
        // if you don't use Steamworks.NET, or add your own defines.
        private const string DesktopDefines = "STEAMWORKS_NET";
        private const string MobileDefines  = "DISABLESTEAMWORKS";

        // -------- Entry points --------
        public static void Windows() => Run("Windows", BuildTarget.StandaloneWindows64, BuildTargetGroup.Standalone, DesktopDefines, iosAppendCapable: false, preBuild: null,             postBuildFinally: null);
        public static void MacOS()   => Run("macOS",   BuildTarget.StandaloneOSX,       BuildTargetGroup.Standalone, DesktopDefines, iosAppendCapable: false, preBuild: ConfigureMac,     postBuildFinally: null);
        public static void Android() => Run("Android", BuildTarget.Android,             BuildTargetGroup.Android,    MobileDefines,  iosAppendCapable: false, preBuild: ConfigureAndroid, postBuildFinally: ResetAndroidSecrets);
        public static void iOS()     => Run("iOS",     BuildTarget.iOS,                 BuildTargetGroup.iOS,        MobileDefines,  iosAppendCapable: true,  preBuild: null,             postBuildFinally: null);

        public static void BumpVersion()
        {
            var args = ParseArgs();
            var kind = GetArg(args, "-cliBumpKind", "patch");
            try
            {
                Bump(kind);
                AssetDatabase.SaveAssets();
                Log($"Bumped to {PlayerSettings.bundleVersion} (code {PlayerSettings.Android.bundleVersionCode}).");
                WriteReport(args, success: true, message: $"Bumped to {PlayerSettings.bundleVersion}", extra: VersionFacts());
                EditorApplication.Exit(0);
            }
            catch (Exception ex)
            {
                Log($"BumpVersion failed: {ex}");
                WriteReport(args, success: false, message: ex.Message, extra: null);
                EditorApplication.Exit(10);
            }
        }

        public static void PrintVersion()
        {
            var args = ParseArgs();
            Log($"Version: {PlayerSettings.bundleVersion} (code {PlayerSettings.Android.bundleVersionCode}).");
            WriteReport(args, success: true, message: PlayerSettings.bundleVersion, extra: VersionFacts());
            EditorApplication.Exit(0);
        }

        // -------- Core build --------
        private static void Run(
            string label,
            BuildTarget target,
            BuildTargetGroup group,
            string defines,
            bool iosAppendCapable,
            Action<Dictionary<string, string>> preBuild,
            Action postBuildFinally)
        {
            var args = ParseArgs();
            try
            {
                var buildPath = GetArg(args, "-cliBuildPath", null);
                if (string.IsNullOrEmpty(buildPath))
                    throw new Exception("-cliBuildPath is required");

                Log($"{label} -> {buildPath}");

                SetDefines(group, defines);

                preBuild?.Invoke(args);

                var options = BuildOptions.None;
                if (iosAppendCapable && GetBoolArg(args, "-cliIosAppend", true))
                {
                    options |= BuildOptions.AcceptExternalModificationsToPlayer;
                    Log("iOS append mode.");
                }
                if (GetBoolArg(args, "-cliDebug", false))
                {
                    options |= BuildOptions.Development | BuildOptions.AllowDebugging;
                    Log("Development build.");
                }

                EnsureParentDir(buildPath);

                var scenes = GetScenes();
                Log($"Scenes: {scenes.Length} from EditorBuildSettings.");

                var opts = new BuildPlayerOptions
                {
                    scenes           = scenes,
                    locationPathName = buildPath,
                    target           = target,
                    options          = options
                };

                var report = BuildPipeline.BuildPlayer(opts);
                var summary = report.summary;
                var ok = summary.result == BuildResult.Succeeded;

                var extra = VersionFacts();
                extra["target"]             = target.ToString();
                extra["outputPath"]         = buildPath;
                extra["totalSizeBytes"]     = summary.totalSize.ToString();
                extra["totalTimeSeconds"]   = summary.totalTime.TotalSeconds.ToString("F2");
                extra["totalErrors"]        = summary.totalErrors.ToString();
                extra["totalWarnings"]      = summary.totalWarnings.ToString();

                if (ok)
                {
                    Log($"{label} OK ({summary.totalSize / (1024f * 1024f):F1} MB, {summary.totalTime.TotalSeconds:F1}s).");
                    WriteReport(args, success: true, message: $"{label} build succeeded", extra: extra);
                    EditorApplication.Exit(0);
                }
                else
                {
                    Log($"{label} FAILED ({summary.totalErrors} errors).");
                    WriteReport(args, success: false, message: $"{label} build failed ({summary.totalErrors} errors)", extra: extra);
                    EditorApplication.Exit(2);
                }
            }
            catch (Exception ex)
            {
                Log($"{label} exception: {ex}");
                WriteReport(args, success: false, message: ex.Message, extra: null);
                EditorApplication.Exit(3);
            }
            finally
            {
                try { postBuildFinally?.Invoke(); } catch { /* swallow */ }
            }
        }

        // Scenes come from EditorBuildSettings.scenes — whatever you have
        // enabled in File → Build Settings is what ships.
        private static string[] GetScenes()
        {
            var list = new List<string>();
            foreach (var s in EditorBuildSettings.scenes)
            {
                if (s.enabled && !string.IsNullOrEmpty(s.path))
                    list.Add(s.path);
            }
            if (list.Count == 0)
                throw new Exception("EditorBuildSettings.scenes has no enabled scenes. Open File → Build Settings in Unity and add at least one scene.");
            return list.ToArray();
        }

        // -------- Platform-specific pre-build setup --------
        private static void ConfigureAndroid(Dictionary<string, string> args)
        {
            EditorUserBuildSettings.buildAppBundle = true;

            var keystorePath = GetArg(args, "-cliKeystorePath", null);
            if (string.IsNullOrEmpty(keystorePath))
                throw new Exception("-cliKeystorePath is required for Android builds.");
            if (!Path.IsPathRooted(keystorePath))
                keystorePath = Path.GetFullPath(keystorePath);

            var keystorePass = GetArg(args, "-cliKeystorePass", null);
            var aliasName    = GetArg(args, "-cliKeyaliasName", PlayerSettings.Android.keyaliasName);
            var aliasPass    = GetArg(args, "-cliKeyaliasPass", keystorePass);

            if (!File.Exists(keystorePath))
                throw new Exception($"Keystore missing: {keystorePath}");
            if (string.IsNullOrEmpty(keystorePass))
                throw new Exception("Android keystore password missing (-cliKeystorePass).");
            if (string.IsNullOrEmpty(aliasName))
                throw new Exception("Android key alias name missing (-cliKeyaliasName or Project Settings).");

            PlayerSettings.Android.useCustomKeystore = true;
            PlayerSettings.Android.keystoreName      = keystorePath;
            PlayerSettings.Android.keystorePass      = keystorePass;
            PlayerSettings.Android.keyaliasName      = aliasName;
            PlayerSettings.Android.keyaliasPass      = aliasPass;

            Log($"Android signing set: alias='{aliasName}' keystore='{keystorePath}'.");
        }

        // Wipe in-memory passwords so they can never serialise to ProjectSettings.asset.
        private static void ResetAndroidSecrets()
        {
            PlayerSettings.Android.keystorePass = string.Empty;
            PlayerSettings.Android.keyaliasPass = string.Empty;
        }

        // Force a universal (Intel + Apple Silicon) macOS binary. Uses reflection
        // so this editor script still compiles on Windows boxes without the
        // StandaloneOSX build support module installed.
        private static void ConfigureMac(Dictionary<string, string> args)
        {
            try
            {
                var t = Type.GetType("UnityEditor.OSXStandalone.UserBuildSettings, UnityEditor.OSXStandalone.Extensions")
                     ?? Type.GetType("UnityEditor.OSXStandalone.UserBuildSettings, UnityEditor");
                if (t == null) { Log("ConfigureMac: OSXStandalone type not found, skipping."); return; }
                var prop = t.GetProperty("architecture", BindingFlags.Public | BindingFlags.Static);
                if (prop == null) { Log("ConfigureMac: 'architecture' property missing, skipping."); return; }
                var enumType = prop.PropertyType;
                object value = null;
                try { value = Enum.Parse(enumType, "x64ARM64"); } catch { }
                if (value == null) { try { value = Enum.Parse(enumType, "Universal"); } catch { } }
                if (value == null) { Log("ConfigureMac: no universal enum value, skipping."); return; }
                prop.SetValue(null, value);
                Log("macOS architecture -> Universal (x64 + arm64).");
            }
            catch (Exception e)
            {
                Log($"ConfigureMac skipped: {e.Message}");
            }
        }

        // -------- Version bump --------
        private static void Bump(string kind)
        {
            var current = PlayerSettings.bundleVersion ?? "0.0.0";
            var parts = current.Split('.');
            int major = parts.Length > 0 ? SafeInt(parts[0]) : 0;
            int minor = parts.Length > 1 ? SafeInt(parts[1]) : 0;
            int patch = parts.Length > 2 ? SafeInt(parts[2]) : 0;

            switch ((kind ?? "patch").ToLowerInvariant())
            {
                case "major": major++; minor = 0; patch = 0; break;
                case "minor": minor++; patch = 0; break;
                case "patch": patch++; break;
                case "none":  break;
                default: throw new Exception($"Unknown -cliBumpKind '{kind}'. Use major|minor|patch|none.");
            }

            PlayerSettings.bundleVersion = $"{major}.{minor}.{patch}";

            var nextCode = PlayerSettings.Android.bundleVersionCode + (kind == "none" ? 0 : 1);
            PlayerSettings.Android.bundleVersionCode = nextCode;
            PlayerSettings.iOS.buildNumber           = nextCode.ToString();
            try { PlayerSettings.macOS.buildNumber = nextCode.ToString(); } catch { /* older Unity */ }
        }

        private static int SafeInt(string s) => int.TryParse(s, out var v) ? v : 0;

        private static Dictionary<string, string> VersionFacts() => new Dictionary<string, string>
        {
            ["bundleVersion"]                = PlayerSettings.bundleVersion ?? string.Empty,
            ["androidBundleVersionCode"]     = PlayerSettings.Android.bundleVersionCode.ToString(),
            ["iOSBuildNumber"]               = PlayerSettings.iOS.buildNumber ?? string.Empty,
            ["macOSBuildNumber"]             = SafeMacBuildNumber(),
            ["productName"]                  = PlayerSettings.productName ?? string.Empty,
            ["applicationIdentifierAndroid"] = PlayerSettings.GetApplicationIdentifier(NamedBuildTarget.Android) ?? string.Empty,
            ["applicationIdentifieriOS"]     = PlayerSettings.GetApplicationIdentifier(NamedBuildTarget.iOS) ?? string.Empty
        };

        private static string SafeMacBuildNumber()
        {
            try { return PlayerSettings.macOS.buildNumber ?? string.Empty; } catch { return string.Empty; }
        }

        // -------- Shared plumbing --------
        private static void SetDefines(BuildTargetGroup group, string defines)
        {
            var named = NamedBuildTarget.FromBuildTargetGroup(group);
            PlayerSettings.SetScriptingDefineSymbols(named, defines);
            Log($"Defines[{group}] = {defines}");
        }

        private static void EnsureParentDir(string path)
        {
            var parent = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(parent) && !Directory.Exists(parent))
                Directory.CreateDirectory(parent);
        }

        private static Dictionary<string, string> ParseArgs()
        {
            var dict = new Dictionary<string, string>(StringComparer.Ordinal);
            var argv = Environment.GetCommandLineArgs();
            for (int i = 0; i < argv.Length; i++)
            {
                var a = argv[i];
                if (!a.StartsWith("-cli", StringComparison.Ordinal)) continue;
                var val = (i + 1 < argv.Length && !argv[i + 1].StartsWith("-", StringComparison.Ordinal)) ? argv[i + 1] : "true";
                dict[a] = val;
            }
            return dict;
        }

        private static string GetArg(Dictionary<string, string> args, string key, string fallback)
            => args.TryGetValue(key, out var v) && !string.IsNullOrEmpty(v) ? v : fallback;

        private static bool GetBoolArg(Dictionary<string, string> args, string key, bool fallback)
        {
            if (!args.TryGetValue(key, out var v) || string.IsNullOrEmpty(v)) return fallback;
            return v.Equals("true", StringComparison.OrdinalIgnoreCase)
                || v.Equals("1",    StringComparison.OrdinalIgnoreCase)
                || v.Equals("yes",  StringComparison.OrdinalIgnoreCase);
        }

        private static void WriteReport(Dictionary<string, string> args, bool success, string message, Dictionary<string, string> extra)
        {
            if (!args.TryGetValue("-cliReportPath", out var path) || string.IsNullOrEmpty(path)) return;
            try
            {
                EnsureParentDir(path);
                var sb = new System.Text.StringBuilder();
                sb.Append("{");
                sb.Append("\"success\":").Append(success ? "true" : "false").Append(",");
                sb.Append("\"message\":\"").Append(Escape(message)).Append("\"");
                if (extra != null)
                {
                    foreach (var kvp in extra)
                    {
                        sb.Append(",\"").Append(Escape(kvp.Key)).Append("\":\"").Append(Escape(kvp.Value)).Append("\"");
                    }
                }
                sb.Append("}");
                File.WriteAllText(path, sb.ToString());
            }
            catch (Exception e)
            {
                Log($"Report write failed: {e.Message}");
            }
        }

        private static string Escape(string s)
            => (s ?? string.Empty)
                .Replace("\\", "\\\\")
                .Replace("\"", "\\\"")
                .Replace("\r", "\\r")
                .Replace("\n", "\\n")
                .Replace("\t", "\\t");

        private static void Log(string msg) => Debug.Log($"{LogPrefix} {msg}");
    }
}
