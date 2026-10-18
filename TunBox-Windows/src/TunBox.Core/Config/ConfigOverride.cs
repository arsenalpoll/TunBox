using System.Text;
using System.Text.Json.Nodes;
using Jint;
using TunBox.Core.Models;
using YamlDotNet.RepresentationModel;

namespace TunBox.Core.Config;

/// <summary>覆写结果：最终 yaml + 没有生效的环节说明（内核照常拿到一份可用配置）。</summary>
public sealed record OverrideResult(string Yaml, string? Note);

/// <summary>
/// 覆写引擎（对齐 FlClash 的 Override）：
/// ① Merge 覆写 —— 一段 YAML 深合并进最终配置：映射递归合并、数组整体替换、标量覆盖；
/// ② Script 覆写 —— 一段 JS（function main(config) { ...; return config; }），
///    config 以 JSON 对象进入脚本，返回值序列化回 YAML。
/// 任何一个环节抛错都不影响出配置：跳过该环节、把原因写进 Note（内核侧照常启动）。
/// </summary>
public static class ConfigOverride
{
    public static OverrideResult Apply(string baseYaml, AppSettings settings)
    {
        if (!settings.OverrideEnabled) return new OverrideResult(baseYaml, null);
        var yaml = baseYaml;
        var notes = new List<string>();

        if (!string.IsNullOrWhiteSpace(settings.OverrideMergeYaml))
        {
            try { yaml = Merge(yaml, settings.OverrideMergeYaml); }
            catch (Exception e) { notes.Add("Merge 覆写没有生效：" + e.Message); }
        }
        if (!string.IsNullOrWhiteSpace(settings.OverrideScript))
        {
            try { yaml = RunScript(yaml, settings.OverrideScript); }
            catch (Exception e) { notes.Add("Script 覆写没有生效：" + e.Message); }
        }
        return new OverrideResult(yaml, notes.Count > 0 ? string.Join("；", notes) : null);
    }

    /// <summary>把 override 深合并进 base：映射递归、数组与标量以 override 为准。</summary>
    public static string Merge(string baseYaml, string overrideYaml)
    {
        var baseRoot = LoadRoot(baseYaml);
        var overRoot = LoadRoot(overrideYaml);
        if (overRoot == null) return baseYaml;
        if (baseRoot is not YamlMappingNode map)
            return WriteRoot(overRoot);                       // 基础配置不是映射（理论不可能）：整体替换
        var merged = MergeNode(map, overRoot);
        return WriteRoot(merged);
    }

    private static YamlNode? LoadRoot(string yaml)
    {
        if (string.IsNullOrWhiteSpace(yaml)) return null;
        var stream = new YamlStream();
        using var reader = new StringReader(yaml);
        stream.Load(reader);
        return stream.Documents.Count > 0 ? stream.Documents[0].RootNode : null;
    }

    private static YamlNode MergeNode(YamlNode b, YamlNode o)
    {
        if (b is YamlMappingNode bm && o is YamlMappingNode om)
        {
            var merged = new YamlMappingNode();
            foreach (var (key, value) in bm.Children) merged.Children[key] = value;
            foreach (var (key, value) in om.Children)
                merged.Children[key] = merged.Children.TryGetValue(key, out var existing)
                    ? MergeNode(existing, value)
                    : value;
            return merged;
        }
        return o;   // 数组/标量：override 整体接管
    }

    private static string WriteRoot(YamlNode root)
    {
        var stream = new YamlStream(new YamlDocument(root));
        var sb = new StringBuilder();
        using var writer = new StringWriter(sb);
        stream.Save(writer);
        return sb.ToString();
    }

    /// <summary>
    /// 跑用户脚本：yaml → JSON → Jint 执行 main(config) → JSON → yaml。
    /// 脚本没定义 main、没返回对象都算失败，异常把原因带出去。
    /// </summary>
    public static string RunScript(string yaml, string script)
    {
        var json = ToJsonNode(LoadRoot(yaml))?.ToJsonString()
            ?? throw new InvalidOperationException("配置不是合法的 YAML 映射");
        using var engine = new Engine(options =>
        {
            options.TimeoutInterval(TimeSpan.FromSeconds(5));   // 脚本死循环不能拖死配置生成
            options.LimitRecursion(64);
        });
        engine.Execute(script);
        engine.SetValue("__configJson", json);
        // 调用与序列化都在脚本侧完成：main 的返回值不用搬回宿主，直接 stringify 成 JSON。
        var engineJson = engine.Evaluate(
            "typeof main === 'function' ? JSON.stringify(main(JSON.parse(__configJson)) ?? null) : null").AsString();
        if (engineJson == null || engineJson == "null")
            throw new InvalidOperationException("脚本没有定义 function main(config)，或它没返回配置对象");
        return JsonToYaml(JsonNode.Parse(engineJson));
    }

    // ── YAML ↔ JSON 双向转换（都走内存里的节点树，不落盘）────────────────

    private static JsonNode? ToJsonNode(YamlNode? node)
    {
        switch (node)
        {
            case null:
                return null;
            case YamlMappingNode m:
                var obj = new JsonObject();
                foreach (var (key, value) in m.Children)
                    obj[key.GetScalarText()] = ToJsonNode(value);
                return obj;
            case YamlSequenceNode s:
                var arr = new JsonArray();
                foreach (var item in s.Children) arr.Add(ToJsonNode(item));
                return arr;
            case YamlScalarNode scalar:
                if (scalar.Value == null) return null;
                // 带引号的数字是字符串，不是数（端口 "443" 也得保持原样语义清晰）
                if (scalar.Style is YamlDotNet.Core.ScalarStyle.SingleQuoted
                    or YamlDotNet.Core.ScalarStyle.DoubleQuoted)
                    return scalar.Value;
                if (bool.TryParse(scalar.Value, out var b)) return b;
                if (long.TryParse(scalar.Value, out var l)) return l;
                if (double.TryParse(scalar.Value, out var d)) return d;
                return scalar.Value;
            default:
                return null;
        }
    }

    public static string JsonToYaml(JsonNode? node)
    {
        var value = FromJsonNode(node);
        var serializer = new YamlDotNet.Serialization.SerializerBuilder()
            .WithIndentedSequences()
            .Build();
        return serializer.Serialize(value!);
    }

    private static object? FromJsonNode(JsonNode? node)
    {
        switch (node)
        {
            case null: return null;
            case JsonObject obj:
                var dict = new Dictionary<string, object?>();
                foreach (var (key, value) in obj) dict[key] = FromJsonNode(value);
                return dict;
            case JsonArray arr:
                var list = new List<object?>();
                foreach (var item in arr) list.Add(FromJsonNode(item));
                return list;
            case JsonValue v when v.TryGetValue<bool>(out var b): return b;
            case JsonValue v when v.TryGetValue<long>(out var l): return l;
            case JsonValue v when v.TryGetValue<double>(out var d): return d;
            case JsonValue v: return v.GetValue<string>();
            default: return null;
        }
    }
}

internal static class YamlNodeExtensions
{
    public static string GetScalarText(this YamlNode node) => node is YamlScalarNode s ? s.Value ?? "" : node.ToString() ?? "";
}
