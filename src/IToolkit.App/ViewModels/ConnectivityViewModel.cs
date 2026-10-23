namespace IToolkit.App.ViewModels;

using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Services.Connectivity;

public class ConnectivityViewModel : ViewModelBase
{
    private readonly IConnectivityService _connectivityService;
    private readonly IPrinterService _printerService;

    private PointAndPrintPreset _selectedPreset = PointAndPrintPreset.Compatibility;
    private string? _selectedErrorCode = "0x0000011b";
    private string _printerDiagnosticsHost = "192.168.1.100";
    private string _networkAdapterName = "Ethernet";
    private string _lastNetworkStatus = "Ready";
    private string _lastPrinterStatus = "Ready";

    public ConnectivityViewModel(
        IConnectivityService connectivityService,
        IPrinterService printerService,
        IActivityLogger? logger = null)
        : base(logger)
    {
        _connectivityService = connectivityService ?? throw new ArgumentNullException(nameof(connectivityService));
        _printerService = printerService ?? throw new ArgumentNullException(nameof(printerService));

        AvailablePresets = new[] { PointAndPrintPreset.Compatibility, PointAndPrintPreset.StrictAdminOnly };
        SupportedErrorCodes = _printerService.GetSupportedErrorCodes();

        // Commands
        RemediateNetworkStackCommand = new AsyncRelayCommand(RemediateNetworkStackAsync, () => IsNotBusy);
        FlushDnsCommand = new AsyncRelayCommand(FlushDnsAsync, () => IsNotBusy);
        RenewDhcpCommand = new AsyncRelayCommand(RenewDhcpAsync, () => IsNotBusy);
        ClearArpCommand = new AsyncRelayCommand(ClearArpAsync, () => IsNotBusy);
        ResetWinsockCommand = new AsyncRelayCommand(ResetWinsockAsync, () => IsNotBusy);
        ResetTcpIpCommand = new AsyncRelayCommand(ResetTcpIpAsync, () => IsNotBusy);
        ConfigureSmbSharingCommand = new AsyncRelayCommand(ConfigureSmbSharingAsync, () => IsNotBusy);
        RestartAdapterCommand = new AsyncRelayCommand(RestartAdapterAsync, () => IsNotBusy);

        PurgeSpoolerCommand = new AsyncRelayCommand(PurgeSpoolerAsync, () => IsNotBusy);
        RegisterSpoolerCommand = new AsyncRelayCommand(RegisterSpoolerAsync, () => IsNotBusy);
        ResetNePortsCommand = new AsyncRelayCommand(ResetNePortsAsync, () => IsNotBusy);
        ApplyPointAndPrintCommand = new AsyncRelayCommand(ApplyPointAndPrintAsync, () => IsNotBusy);
        RemediatePrinterErrorCommand = new AsyncRelayCommand(RemediatePrinterErrorAsync, () => IsNotBusy && !string.IsNullOrEmpty(SelectedErrorCode));
        DiagnosePrinterHostCommand = new AsyncRelayCommand(DiagnosePrinterHostAsync, () => IsNotBusy && !string.IsNullOrEmpty(PrinterDiagnosticsHost));
    }

    public IReadOnlyList<PointAndPrintPreset> AvailablePresets { get; }
    public IReadOnlyList<string> SupportedErrorCodes { get; }

    public PointAndPrintPreset SelectedPreset
    {
        get => _selectedPreset;
        set => SetProperty(ref _selectedPreset, value);
    }

    public string? SelectedErrorCode
    {
        get => _selectedErrorCode;
        set
        {
            if (SetProperty(ref _selectedErrorCode, value))
            {
                RemediatePrinterErrorCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public string PrinterDiagnosticsHost
    {
        get => _printerDiagnosticsHost;
        set
        {
            if (SetProperty(ref _printerDiagnosticsHost, value))
            {
                DiagnosePrinterHostCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public string NetworkAdapterName
    {
        get => _networkAdapterName;
        set => SetProperty(ref _networkAdapterName, value);
    }

    public string LastNetworkStatus
    {
        get => _lastNetworkStatus;
        set => SetProperty(ref _lastNetworkStatus, value);
    }

    public string LastPrinterStatus
    {
        get => _lastPrinterStatus;
        set => SetProperty(ref _lastPrinterStatus, value);
    }

    public IAsyncRelayCommand RemediateNetworkStackCommand { get; }
    public IAsyncRelayCommand FlushDnsCommand { get; }
    public IAsyncRelayCommand RenewDhcpCommand { get; }
    public IAsyncRelayCommand ClearArpCommand { get; }
    public IAsyncRelayCommand ResetWinsockCommand { get; }
    public IAsyncRelayCommand ResetTcpIpCommand { get; }
    public IAsyncRelayCommand ConfigureSmbSharingCommand { get; }
    public IAsyncRelayCommand RestartAdapterCommand { get; }

    public IAsyncRelayCommand PurgeSpoolerCommand { get; }
    public IAsyncRelayCommand RegisterSpoolerCommand { get; }
    public IAsyncRelayCommand ResetNePortsCommand { get; }
    public IAsyncRelayCommand ApplyPointAndPrintCommand { get; }
    public IAsyncRelayCommand RemediatePrinterErrorCommand { get; }
    public IAsyncRelayCommand DiagnosePrinterHostCommand { get; }

    private async Task RemediateNetworkStackAsync() => await ExecuteAsync("Full Network Stack Remediation", () =>
    {
        var res = _connectivityService.RemediateNetworkStack();
        LastNetworkStatus = res.Success
            ? $"Remediated: DNS flushed, DHCP renewed, ARP cleared, Winsock/TCP-IP/NLA/Proxy reset. {(res.RequiresReboot ? "[Reboot Recommended]" : string.Empty)}"
            : $"Network remediation failed: {res.Message}";
        return Task.CompletedTask;
    });

    private async Task FlushDnsAsync() => await ExecuteAsync("Flush DNS", () =>
    {
        bool ok = _connectivityService.FlushDns();
        LastNetworkStatus = ok ? "DNS Resolver Cache flushed successfully." : "Failed to flush DNS cache.";
        return Task.CompletedTask;
    });

    private async Task RenewDhcpAsync() => await ExecuteAsync("Renew DHCP Lease", () =>
    {
        bool ok = _connectivityService.ReleaseRenewDhcp();
        LastNetworkStatus = ok ? "DHCP lease released and renewed successfully." : "Failed to renew DHCP lease.";
        return Task.CompletedTask;
    });

    private async Task ClearArpAsync() => await ExecuteAsync("Clear ARP Cache", () =>
    {
        bool ok = _connectivityService.ClearArpAndRouteCache();
        LastNetworkStatus = ok ? "ARP and route tables flushed successfully." : "Failed to clear ARP cache.";
        return Task.CompletedTask;
    });

    private async Task ResetWinsockAsync() => await ExecuteAsync("Reset Winsock Catalog", () =>
    {
        bool ok = _connectivityService.ResetWinsock();
        LastNetworkStatus = ok ? "Winsock Catalog reset successfully. Reboot recommended." : "Failed to reset Winsock.";
        return Task.CompletedTask;
    });

    private async Task ResetTcpIpAsync() => await ExecuteAsync("Reset TCP/IP Stack", () =>
    {
        bool ok = _connectivityService.ResetTcpIpStack();
        LastNetworkStatus = ok ? "TCP/IP stack reset successfully. Reboot recommended." : "Failed to reset TCP/IP.";
        return Task.CompletedTask;
    });

    private async Task ConfigureSmbSharingAsync() => await ExecuteAsync("Configure SMB Sharing", () =>
    {
        var res = _connectivityService.ConfigureSmbSharing();
        LastNetworkStatus = res.Success ? "SMB sharing configured (InsecureGuestAuth=1, firewall rules, Lanman services)." : $"SMB config failed: {res.Message}";
        return Task.CompletedTask;
    });

    private async Task RestartAdapterAsync() => await ExecuteAsync($"Restart Adapter '{NetworkAdapterName}'", () =>
    {
        bool ok = _connectivityService.RestartAdapter(NetworkAdapterName);
        LastNetworkStatus = ok ? $"Adapter '{NetworkAdapterName}' restarted successfully." : $"Failed to restart adapter '{NetworkAdapterName}'.";
        return Task.CompletedTask;
    });

    private async Task PurgeSpoolerAsync() => await ExecuteAsync("Purge Print Spooler Queue", () =>
    {
        var res = _printerService.PurgeSpoolerQueue();
        LastPrinterStatus = res.Success ? $"Spooler purged: {res.PurgedFilesCount} spool files deleted, service restarted." : $"Purge failed: {res.Message}";
        return Task.CompletedTask;
    });

    private async Task RegisterSpoolerAsync() => await ExecuteAsync("Re-Register Spooler Components", () =>
    {
        bool ok = _printerService.RegisterSpoolerComponents();
        LastPrinterStatus = ok ? "Spooler DLLs and MOF repository re-registered successfully." : "Failed to register spooler components.";
        return Task.CompletedTask;
    });

    private async Task ResetNePortsAsync() => await ExecuteAsync("Reset Virtual NeXX Ports", () =>
    {
        int count = _printerService.ResetNePortBindings();
        LastPrinterStatus = $"Reset {count} virtual NeXX: printer port registry bindings.";
        return Task.CompletedTask;
    });

    private async Task ApplyPointAndPrintAsync() => await ExecuteAsync($"Apply Point & Print: {SelectedPreset}", () =>
    {
        bool ok = _printerService.ApplyPointAndPrintPreset(SelectedPreset);
        LastPrinterStatus = ok ? $"Point & Print preset '{SelectedPreset}' applied successfully." : "Failed to apply Point & Print policy.";
        return Task.CompletedTask;
    });

    private async Task RemediatePrinterErrorAsync() => await ExecuteAsync($"Remediate Error {SelectedErrorCode}", () =>
    {
        if (SelectedErrorCode == null) return Task.CompletedTask;
        var res = _printerService.RemediatePrinterError(SelectedErrorCode);
        LastPrinterStatus = res.Success ? $"Remediated {SelectedErrorCode}: {res.RemediationAction}" : $"Remediation failed: {res.Message}";
        return Task.CompletedTask;
    });

    private async Task DiagnosePrinterHostAsync() => await ExecuteAsync($"Diagnose Host '{PrinterDiagnosticsHost}'", () =>
    {
        var res = _connectivityService.DiagnosePrinterPortConnectivity(PrinterDiagnosticsHost);
        LastPrinterStatus = $"Host {res.Host}: Ping={(res.IsPingSuccessful ? "OK" : "Fail")}, SMB445={(res.IsSmbPortOpen ? "Open" : "Closed")}, RPC135={(res.IsRpcPortOpen ? "Open" : "Closed")}, RAW9100={(res.IsRawPortOpen ? "Open" : "Closed")}";
        return Task.CompletedTask;
    });
}
