using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Linq;
using TunBox.Core.Config;
using TunBox.Core.Services;
using TunBox.Core.Storage;

namespace TunBox.Core.Models;

/// <summary>
/// 单一状态源（Single Source of Truth），对齐 FlClash 的 Config + Riverpod 模式。
///
/// 整个应用的全部可变状态都持在此单例里：
///   - Settings: 持久化到 settings.json（Workspace.LoadSettings/SaveSettings）
///   - Nodes/Groups/Subscriptions: 持久化到 nodes.json（Workspace.LoadNodes/SaveNodes）
///   - TunnelState / TunActive / CoreAlive: 运行期内核状态
///   - LastError / LastDrop / PendingConfigNote / LastOverrideNote: 最后一次操作的元信息
///
/// 所有模块（ConnectionManager、MainViewModel、UI）只通过 AppState.Current 读写状态，
/// 不再各自持有一份 Settings/Nodes/副本，杜绝「四套账不一致」。
///
/// 线程安全：UI 线程读写；跨线程（测速回调、内核事件）通过 Changed 事件异步通知 UI。
/// </summary>
public sealed class AppState : INotifyPropertyChanged
{
    public static AppState Current { get; } = new();

    public event PropertyChangedEventHandler? PropertyChanged;
    /// <summary>任何状态变更后触发，UI 订阅以刷新。</summary>
    public event Action? Changed;

    private AppState() { }

    // ── 持久化设置 ──
    public AppSettings Settings { get; set; } = new();

    // ── 节点库 ──
    public List<ProxyNode> Nodes { get; set; } = new();
    public List<ProxyGroup> Groups { get; set; } = new();
    public List<Subscription> Subscriptions { get; set; } = new();

    // ── 运行期内核状态 ──
    private TunnelState _tunnelState = TunnelState.Disconnected;
    public TunnelState TunnelState
    {
        get => _tunnelState;
        private set { if (_tunnelState != value) { _tunnelState = value; OnPropertyChanged(); Changed?.Invoke(); } }
    }

    public bool CoreAlive => TunnelState is TunnelState.Connected or TunnelState.Standby;
    private bool _tunActive;
    public bool TunActive
    {
        get => _tunActive;
        private set { if (_tunActive != value) { _tunActive = value; OnPropertyChanged(); Changed?.Invoke(); } }
    }

    // ── 最后一次操作元信息 ──
    public string? LastError { get; private set; }
    public ProxyDropStats? LastDrop { get; private set; }
    public string? PendingConfigNote { get; private set; }
    public string? LastOverrideNote { get; private set; }
    public IReadOnlyList<string> ImportWarnings { get; private set; } = Array.Empty<string>();

    // ── smart 组就绪判断 ──
    public bool SmartGroupReady => Settings.UseSmartGroup
        && Nodes.Count >= 2;

    internal void SetTunnelState(TunnelState state) => TunnelState = state;
    internal void SetTunActive(bool active) => TunActive = active;

    internal void SetLastError(string? error)
    {
        LastError = error;
        Changed?.Invoke();
    }

    internal void SetLastDrop(ProxyDropStats? drop)
    {
        LastDrop = drop;
        Changed?.Invoke();
    }

    internal void SetPendingConfigNote(string? note)
    {
        PendingConfigNote = note;
        Changed?.Invoke();
    }

    internal void SetLastOverrideNote(string? note)
    {
        LastOverrideNote = note;
        Changed?.Invoke();
    }

    internal void SetImportWarnings(IReadOnlyList<string> warnings)
    {
        ImportWarnings = warnings;
        Changed?.Invoke();
    }

    internal void MarkNodesDirty() => Changed?.Invoke();

    private void OnPropertyChanged([System.Runtime.CompilerServices.CallerMemberName] string? name = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
