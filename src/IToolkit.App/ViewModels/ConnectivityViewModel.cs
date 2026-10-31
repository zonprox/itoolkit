namespace IToolkit.App.ViewModels;

using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Threading.Tasks;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Services.Connectivity;

public class ConnectivityViewModel : ViewModelBase
{
    private readonly IConnectivityService _connectivityService;
    private readonly IPrinterService _printerService;
    private readonly INetworkService? _networkService;
    private readonly ISafetyConfirmationService? _confirmationService;
    private readonly IDialogService? _dialogService;

    private PointAndPrintPreset _selectedPreset = PointAndPrintPreset.Compatibility;
    private string? _selectedErrorCode = "0x0000011b";
    private string _printerDiagnosticsHost = "192.168.1.100";
    private string _networkAdapterName = "Ethernet";
    private NetworkAdapterInfo? _selectedAdapter;
    private string _lastNetworkStatus = "Ready";
    private string _lastPrinterStatus = "Ready";

    // Per-Adapter popup state
    private bool _isAdapterEditPopupOpen;
    private NetworkAdapterInfo? _selectedEditingAdapter;
    private bool _adapterUseDhcpIp = true;
    private string _adapterStaticIp = "";
    private string _adapterSubnetMask = "255.255.255.0";
    private string _adapterDefaultGateway = "";
    private bool _adapterUseDhcpDns = true;
    private string _adapterPreferredDns = "";
    private string _adapterAlternateDns = "";
    private int _adapterMtu = 1500;

    // Per-Printer popup state
    private bool _isPrinterEditPopupOpen;
    private PrinterInfo? _selectedEditingPrinter;
    private PrinterInfo? _selectedPrinter;

    public ConnectivityViewModel(
        IConnectivityService connectivityService,
        IPrinterService printerService,
        IActivityLogger? logger = null,
        INetworkService? networkService = null,
        ISafetyConfirmationService? confirmationService = null,
        IDialogService? dialogService = null)
        : base(logger)
    {
        _connectivityService = connectivityService ?? throw new ArgumentNullException(nameof(connectivityService));
        _printerService = printerService ?? throw new ArgumentNullException(nameof(printerService));
        _networkService = networkService;
        _confirmationService = confirmationService;
        _dialogService = dialogService;

        AvailablePresets = new[] { PointAndPrintPreset.Compatibility, PointAndPrintPreset.StrictAdminOnly };
        SupportedErrorCodes = _printerService.GetSupportedErrorCodes();

        // Global Network Commands
        RemediateNetworkStackCommand = new AsyncRelayCommand(RemediateNetworkStackAsync, () => IsNotBusy);
        FlushDnsCommand = new AsyncRelayCommand(FlushDnsAsync, () => IsNotBusy);
        RenewDhcpCommand = new AsyncRelayCommand(RenewDhcpAsync, () => IsNotBusy);
        ClearArpCommand = new AsyncRelayCommand(ClearArpAsync, () => IsNotBusy);
        ResetWinsockCommand = new AsyncRelayCommand(ResetWinsockAsync, () => IsNotBusy);
        ResetTcpIpCommand = new AsyncRelayCommand(ResetTcpIpAsync, () => IsNotBusy);
        ConfigureSmbSharingCommand = new AsyncRelayCommand(ConfigureSmbSharingAsync, () => IsNotBusy);
        RestartAdapterCommand = new AsyncRelayCommand(RestartAdapterAsync, () => IsNotBusy);
        RefreshAdaptersCommand = new AsyncRelayCommand(RefreshAdaptersAsync, () => IsNotBusy);

        // Per-Adapter Popup Commands
        OpenAdapterEditPopupCommand = new RelayCommand(OpenAdapterEditPopup, _ => IsNotBusy && (SelectedAdapter != null || AvailableAdapters.Count > 0));
        OpenAdapterEditPopupForItemCommand = new RelayCommand(OpenAdapterEditPopup);
        SaveAdapterIpConfigCommand = new AsyncRelayCommand(SaveAdapterIpConfigAsync, () => IsNotBusy && SelectedEditingAdapter != null);
        SaveAdapterDnsConfigCommand = new AsyncRelayCommand(SaveAdapterDnsConfigAsync, () => IsNotBusy && SelectedEditingAdapter != null);
        SetAdapterMtuCommand = new AsyncRelayCommand(SetAdapterMtuAsync, () => IsNotBusy && SelectedEditingAdapter != null);
        ToggleAdapterEnableCommand = new AsyncRelayCommand(ToggleAdapterEnableAsync, () => IsNotBusy && SelectedEditingAdapter != null);
        RenewAdapterDhcpCommand = new AsyncRelayCommand(RenewAdapterDhcpAsync, () => IsNotBusy && SelectedEditingAdapter != null);
        CloseAdapterEditPopupCommand = new RelayCommand(CloseAdapterEditPopup);

        // Global Printer Commands
        PurgeSpoolerCommand = new AsyncRelayCommand(PurgeSpoolerAsync, () => IsNotBusy);
        RegisterSpoolerCommand = new AsyncRelayCommand(RegisterSpoolerAsync, () => IsNotBusy);
        ResetNePortsCommand = new AsyncRelayCommand(ResetNePortsAsync, () => IsNotBusy);
        ApplyPointAndPrintCommand = new AsyncRelayCommand(ApplyPointAndPrintAsync, () => IsNotBusy);
        RemediatePrinterErrorCommand = new AsyncRelayCommand(RemediatePrinterErrorAsync, () => IsNotBusy && !string.IsNullOrEmpty(SelectedErrorCode));
        DiagnosePrinterHostCommand = new AsyncRelayCommand(DiagnosePrinterHostAsync, () => IsNotBusy && !string.IsNullOrEmpty(PrinterDiagnosticsHost));

        RemediateAllPrintersCommand = new AsyncRelayCommand(RemediateAllPrintersAsync, () => IsNotBusy);
        RemediateClientBatchCommand = new AsyncRelayCommand(RemediateClientBatchAsync, () => IsNotBusy);
        RemediateServerBatchCommand = new AsyncRelayCommand(RemediateServerBatchAsync, () => IsNotBusy);
        AuditPointAndPrintPolicyCommand = new AsyncRelayCommand(AuditPointAndPrintPolicyAsync, () => IsNotBusy);
        RefreshPrinterConnectionsCommand = new AsyncRelayCommand(RefreshPrinterConnectionsAsync, () => IsNotBusy);
        InspectSpoolerStatusCommand = new AsyncRelayCommand(InspectSpoolerStatusAsync, () => IsNotBusy);

        // Per-Printer Popup Commands
        RefreshPrintersCommand = new AsyncRelayCommand(RefreshPrintersAsync, () => IsNotBusy);
        OpenPrinterEditPopupCommand = new RelayCommand(OpenPrinterEditPopup, _ => IsNotBusy && (SelectedPrinter != null || AvailablePrinters.Count > 0));
        OpenPrinterEditPopupForItemCommand = new RelayCommand(OpenPrinterEditPopup);
        PrintTestPageCommand = new AsyncRelayCommand(PrintTestPageAsync, () => IsNotBusy && SelectedEditingPrinter != null);
        PurgeTargetPrinterQueueCommand = new AsyncRelayCommand(PurgeTargetPrinterQueueAsync, () => IsNotBusy && SelectedEditingPrinter != null);
        SetAsDefaultPrinterCommand = new AsyncRelayCommand(SetAsDefaultPrinterAsync, () => IsNotBusy && SelectedEditingPrinter != null);
        ResetTargetPrinterConnectionCommand = new AsyncRelayCommand(ResetTargetPrinterConnectionAsync, () => IsNotBusy && SelectedEditingPrinter != null);
        ClosePrinterEditPopupCommand = new RelayCommand(ClosePrinterEditPopup);
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

    public ObservableCollection<NetworkAdapterInfo> AvailableAdapters { get; } = new();

    public NetworkAdapterInfo? SelectedAdapter
    {
        get => _selectedAdapter;
        set
        {
            if (SetProperty(ref _selectedAdapter, value))
            {
                if (value != null)
                {
                    NetworkAdapterName = value.Name;
                }
                RestartAdapterCommand.RaiseCanExecuteChanged();
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
    public IAsyncRelayCommand RefreshAdaptersCommand { get; }

    public IAsyncRelayCommand PurgeSpoolerCommand { get; }
    public IAsyncRelayCommand RegisterSpoolerCommand { get; }
    public IAsyncRelayCommand ResetNePortsCommand { get; }
    public IAsyncRelayCommand ApplyPointAndPrintCommand { get; }
    public IAsyncRelayCommand RemediatePrinterErrorCommand { get; }
    public IAsyncRelayCommand DiagnosePrinterHostCommand { get; }

    public IAsyncRelayCommand RemediateAllPrintersCommand { get; }
    public IAsyncRelayCommand RemediateClientBatchCommand { get; }
    public IAsyncRelayCommand RemediateServerBatchCommand { get; }
    public IAsyncRelayCommand AuditPointAndPrintPolicyCommand { get; }
    public IAsyncRelayCommand RefreshPrinterConnectionsCommand { get; }
    public IAsyncRelayCommand InspectSpoolerStatusCommand { get; }

    // Per-Adapter Popup Commands
    public IRelayCommand OpenAdapterEditPopupCommand { get; }
    public IRelayCommand OpenAdapterEditPopupForItemCommand { get; }
    public IAsyncRelayCommand SaveAdapterIpConfigCommand { get; }
    public IAsyncRelayCommand SaveAdapterDnsConfigCommand { get; }
    public IAsyncRelayCommand SetAdapterMtuCommand { get; }
    public IAsyncRelayCommand ToggleAdapterEnableCommand { get; }
    public IAsyncRelayCommand RenewAdapterDhcpCommand { get; }
    public IRelayCommand CloseAdapterEditPopupCommand { get; }

    // Per-Printer Popup Commands
    public IAsyncRelayCommand RefreshPrintersCommand { get; }
    public IRelayCommand OpenPrinterEditPopupCommand { get; }
    public IRelayCommand OpenPrinterEditPopupForItemCommand { get; }
    public IAsyncRelayCommand PrintTestPageCommand { get; }
    public IAsyncRelayCommand PurgeTargetPrinterQueueCommand { get; }
    public IAsyncRelayCommand SetAsDefaultPrinterCommand { get; }
    public IAsyncRelayCommand ResetTargetPrinterConnectionCommand { get; }
    public IRelayCommand ClosePrinterEditPopupCommand { get; }

    public ObservableCollection<PrinterInfo> AvailablePrinters { get; } = new();

    public PrinterInfo? SelectedPrinter
    {
        get => _selectedPrinter;
        set
        {
            if (SetProperty(ref _selectedPrinter, value))
            {
                OpenPrinterEditPopupCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public bool IsAdapterEditPopupOpen
    {
        get => _isAdapterEditPopupOpen;
        set => SetProperty(ref _isAdapterEditPopupOpen, value);
    }

    public NetworkAdapterInfo? SelectedEditingAdapter
    {
        get => _selectedEditingAdapter;
        set
        {
            if (SetProperty(ref _selectedEditingAdapter, value))
            {
                SaveAdapterIpConfigCommand.RaiseCanExecuteChanged();
                SaveAdapterDnsConfigCommand.RaiseCanExecuteChanged();
                SetAdapterMtuCommand.RaiseCanExecuteChanged();
                ToggleAdapterEnableCommand.RaiseCanExecuteChanged();
                RenewAdapterDhcpCommand.RaiseCanExecuteChanged();
                OnPropertyChanged(nameof(EditingAdapterHeaderSummary));
            }
        }
    }

    public string EditingAdapterHeaderSummary => SelectedEditingAdapter != null
        ? $"{SelectedEditingAdapter.Name} ({SelectedEditingAdapter.Description})  |  Status: {SelectedEditingAdapter.Status}"
        : "No Network Adapter Selected";

    public bool AdapterUseDhcpIp
    {
        get => _adapterUseDhcpIp;
        set => SetProperty(ref _adapterUseDhcpIp, value);
    }

    public string AdapterStaticIp
    {
        get => _adapterStaticIp;
        set => SetProperty(ref _adapterStaticIp, value);
    }

    public string AdapterSubnetMask
    {
        get => _adapterSubnetMask;
        set => SetProperty(ref _adapterSubnetMask, value);
    }

    public string AdapterDefaultGateway
    {
        get => _adapterDefaultGateway;
        set => SetProperty(ref _adapterDefaultGateway, value);
    }

    public bool AdapterUseDhcpDns
    {
        get => _adapterUseDhcpDns;
        set => SetProperty(ref _adapterUseDhcpDns, value);
    }

    public string AdapterPreferredDns
    {
        get => _adapterPreferredDns;
        set => SetProperty(ref _adapterPreferredDns, value);
    }

    public string AdapterAlternateDns
    {
        get => _adapterAlternateDns;
        set => SetProperty(ref _adapterAlternateDns, value);
    }

    public int AdapterMtu
    {
        get => _adapterMtu;
        set => SetProperty(ref _adapterMtu, value);
    }

    public bool IsPrinterEditPopupOpen
    {
        get => _isPrinterEditPopupOpen;
        set => SetProperty(ref _isPrinterEditPopupOpen, value);
    }

    public PrinterInfo? SelectedEditingPrinter
    {
        get => _selectedEditingPrinter;
        set
        {
            if (SetProperty(ref _selectedEditingPrinter, value))
            {
                PrintTestPageCommand.RaiseCanExecuteChanged();
                PurgeTargetPrinterQueueCommand.RaiseCanExecuteChanged();
                SetAsDefaultPrinterCommand.RaiseCanExecuteChanged();
                ResetTargetPrinterConnectionCommand.RaiseCanExecuteChanged();
                OnPropertyChanged(nameof(EditingPrinterHeaderSummary));
            }
        }
    }

    public string EditingPrinterHeaderSummary => SelectedEditingPrinter != null
        ? $"{SelectedEditingPrinter.Name}  |  Driver: {SelectedEditingPrinter.DriverName}  |  Port: {SelectedEditingPrinter.PortName} (Jobs: {SelectedEditingPrinter.PendingJobCount})"
        : "No Printer Selected";

    public async Task RefreshAdaptersAsync()
    {
        if (_networkService == null) return;

        try
        {
            Logger?.LogInfo(nameof(ConnectivityViewModel), "Scanning network adapters...");
            var adapters = await Task.Run(() => _networkService.GetAdapters()?.ToList() ?? new List<NetworkAdapterInfo>());
            AvailableAdapters.Clear();
            foreach (var adapter in adapters)
            {
                AvailableAdapters.Add(adapter);
            }

            if (SelectedAdapter == null && AvailableAdapters.Count > 0)
            {
                var active = AvailableAdapters.FirstOrDefault(a => string.Equals(a.Status, "Up", StringComparison.OrdinalIgnoreCase));
                SelectedAdapter = active ?? AvailableAdapters[0];
            }

            LastNetworkStatus = $"Discovered {AvailableAdapters.Count} network adapter(s). Active: {NetworkAdapterName}";
            Logger?.LogInfo(nameof(ConnectivityViewModel), LastNetworkStatus);
        }
        catch (Exception ex)
        {
            LastNetworkStatus = $"Adapter discovery failed: {ex.Message}";
            Logger?.LogError(nameof(ConnectivityViewModel), LastNetworkStatus);
        }
    }

    private async Task RemediateNetworkStackAsync()
    {
        if (_confirmationService != null)
        {
            bool confirmed = await _confirmationService.ConfirmAsync(
                "Confirm Network Stack Remediation",
                "Full Network Stack Remediation will reset Winsock, TCP/IP, ARP, DNS, and DHCP.",
                "All active network connections will be dropped and a system reboot is required. Do you wish to continue?");
            if (!confirmed)
            {
                LastNetworkStatus = "Network remediation cancelled by user.";
                Logger?.LogWarning(nameof(ConnectivityViewModel), "Network stack remediation cancelled by user.");
                return;
            }
        }

        await ExecuteAsync("Full Network Stack Remediation", () =>
        {
            var res = _connectivityService.RemediateNetworkStack();
            LastNetworkStatus = res.Success
                ? $"Remediated: DNS flushed, DHCP renewed, ARP cleared, Winsock/TCP-IP/NLA/Proxy reset. {(res.RequiresReboot ? "[Reboot Recommended]" : string.Empty)}"
                : $"Network remediation failed: {res.Message}";
            return Task.CompletedTask;
        });
    }

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

    private async Task ResetWinsockAsync()
    {
        if (_confirmationService != null)
        {
            bool confirmed = await _confirmationService.ConfirmAsync(
                "Confirm Winsock Reset",
                "Resetting the Winsock catalog will restore default network socket configurations.",
                "Active network connections will be dropped and a system reboot is recommended. Do you wish to continue?");
            if (!confirmed)
            {
                LastNetworkStatus = "Winsock reset cancelled by user.";
                Logger?.LogWarning(nameof(ConnectivityViewModel), "Winsock reset cancelled by user.");
                return;
            }
        }

        await ExecuteAsync("Reset Winsock Catalog", () =>
        {
            bool ok = _connectivityService.ResetWinsock();
            LastNetworkStatus = ok ? "Winsock Catalog reset successfully. Reboot recommended." : "Failed to reset Winsock.";
            return Task.CompletedTask;
        });
    }

    private async Task ResetTcpIpAsync()
    {
        if (_confirmationService != null)
        {
            bool confirmed = await _confirmationService.ConfirmAsync(
                "Confirm TCP/IP Reset",
                "Resetting the TCP/IP stack will rewrite registry configurations to factory defaults.",
                "Active network connections will be dropped and a system reboot is recommended. Do you wish to continue?");
            if (!confirmed)
            {
                LastNetworkStatus = "TCP/IP reset cancelled by user.";
                Logger?.LogWarning(nameof(ConnectivityViewModel), "TCP/IP reset cancelled by user.");
                return;
            }
        }

        await ExecuteAsync("Reset TCP/IP Stack", () =>
        {
            bool ok = _connectivityService.ResetTcpIpStack();
            LastNetworkStatus = ok ? "TCP/IP stack reset successfully. Reboot recommended." : "Failed to reset TCP/IP.";
            return Task.CompletedTask;
        });
    }

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

    private async Task PurgeSpoolerAsync()
    {
        if (_confirmationService != null)
        {
            bool confirmed = await _confirmationService.ConfirmAsync(
                "Confirm Spooler Queue Purge",
                "Purging the Print Spooler queue will permanently delete all pending print jobs across all installed printers.",
                "All active and pending spool files will be removed. Do you wish to continue?");
            if (!confirmed)
            {
                LastPrinterStatus = "Spooler purge cancelled by user.";
                Logger?.LogWarning(nameof(ConnectivityViewModel), "Spooler queue purge cancelled by user.");
                return;
            }
        }

        await ExecuteAsync("Purge Print Spooler Queue", () =>
        {
            var res = _printerService.PurgeSpoolerQueue();
            LastPrinterStatus = res.Success ? $"Spooler purged: {res.PurgedFilesCount} spool files deleted, service restarted." : $"Purge failed: {res.Message}";
            return Task.CompletedTask;
        });
    }

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

    private async Task RemediateAllPrintersAsync()
    {
        if (_confirmationService != null)
        {
            bool confirmed = await _confirmationService.ConfirmAsync(
                "Confirm Full Printer Remediation",
                "Full Printer Remediation will apply both Client and Server policies, reset RPC/named pipes, purge queues, and restart Print Spooler.",
                "Active print jobs will be lost. Do you wish to continue?");
            if (!confirmed)
            {
                LastPrinterStatus = "Full printer remediation cancelled by user.";
                Logger?.LogWarning(nameof(ConnectivityViewModel), "Full printer remediation cancelled by user.");
                return;
            }
        }

        await ExecuteAsync("Remediate All Printers (Client + Server)", () =>
        {
            var res = _printerService.RemediateAll();
            int backupCount = res.BackupPaths?.Count ?? 0;
            LastPrinterStatus = res.Success
                ? $"Remediate All completed: {res.ActionsExecuted.Count} action(s) executed, {backupCount} backup(s) saved, {res.QueuePurgedCount} queue job(s) purged, {res.CleanedNePortsCount} Ne port(s) cleaned."
                : $"Remediate All failed: {res.Message}";

            if (res.Success)
            {
                Logger?.LogSuccess(nameof(ConnectivityViewModel), LastPrinterStatus);
            }
            else
            {
                Logger?.LogError(nameof(ConnectivityViewModel), LastPrinterStatus);
            }

            return Task.CompletedTask;
        });
    }

    private async Task RemediateClientBatchAsync() => await ExecuteAsync("Remediate Client Printers", () =>
    {
        var res = _printerService.RemediateRole(PrinterRemediationRole.Client);
        int backupCount = res.BackupPaths?.Count ?? 0;
        LastPrinterStatus = res.Success
            ? $"Client Batch completed: {res.ActionsExecuted.Count} action(s) executed ({string.Join(", ", res.ActionsExecuted)}), {backupCount} backup(s) saved."
            : $"Client Batch failed: {res.Message}";

        if (res.Success)
        {
            Logger?.LogSuccess(nameof(ConnectivityViewModel), LastPrinterStatus);
        }
        else
        {
            Logger?.LogError(nameof(ConnectivityViewModel), LastPrinterStatus);
        }

        return Task.CompletedTask;
    });

    private async Task RemediateServerBatchAsync() => await ExecuteAsync("Remediate Server Printers", () =>
    {
        var res = _printerService.RemediateRole(PrinterRemediationRole.Server);
        int backupCount = res.BackupPaths?.Count ?? 0;
        LastPrinterStatus = res.Success
            ? $"Server Batch completed: {res.ActionsExecuted.Count} action(s) executed ({string.Join(", ", res.ActionsExecuted)}), {backupCount} backup(s) saved."
            : $"Server Batch failed: {res.Message}";

        if (res.Success)
        {
            Logger?.LogSuccess(nameof(ConnectivityViewModel), LastPrinterStatus);
        }
        else
        {
            Logger?.LogError(nameof(ConnectivityViewModel), LastPrinterStatus);
        }

        return Task.CompletedTask;
    });

    private async Task AuditPointAndPrintPolicyAsync() => await ExecuteAsync("Audit Point & Print Policy", () =>
    {
        var res = _printerService.AuditPointAndPrintPolicy();
        string cveStatus = res.IsVulnerableToCVE20211678 ? "Vulnerable" : "Secured";
        string posture = res.IsVulnerable ? "Vulnerable" : "Hardened";
        LastPrinterStatus = $"Point & Print Policy Audit: Posture={posture}, CVE-2021-1678={cveStatus}, RpcAuthn={(res.RpcAuthnLevelPrivacyEnabled ? "Enabled" : "Disabled")}, RestrictAdmin={(res.RestrictDriverInstallationToAdministrators ? "Enabled" : "Disabled")}. {res.PostureDescription}";

        if (res.IsVulnerable)
        {
            Logger?.LogWarning(nameof(ConnectivityViewModel), LastPrinterStatus);
        }
        else
        {
            Logger?.LogSuccess(nameof(ConnectivityViewModel), LastPrinterStatus);
        }

        return Task.CompletedTask;
    });

    private async Task RefreshPrinterConnectionsAsync() => await ExecuteAsync("Refresh Printer Connections", () =>
    {
        var res = _printerService.ResetPrinterConnections();
        LastPrinterStatus = res.Success
            ? $"Printer connections refreshed: {res.ReconnectedPrinters} reconnected, {res.RemovedStalePrinters} stale removed out of {res.DiscoveredPrinters} discovered."
            : $"Printer connection refresh failed: {res.Message}";

        if (res.Success)
        {
            Logger?.LogSuccess(nameof(ConnectivityViewModel), LastPrinterStatus);
        }
        else
        {
            Logger?.LogError(nameof(ConnectivityViewModel), LastPrinterStatus);
        }

        return Task.CompletedTask;
    });

    private async Task InspectSpoolerStatusAsync() => await ExecuteAsync("Inspect Spooler Status", () =>
    {
        var res = _printerService.GetSpoolerStatus();
        string pidInfo = res.Pid.HasValue ? $" (PID {res.Pid.Value})" : string.Empty;
        LastPrinterStatus = $"Spooler Status: {res.ServiceStatus}{pidInfo}, Queue: {res.PendingJobFileCount} file(s) ({res.TotalQueueSizeBytes} bytes), Directory: {res.SpoolDirectory}. {(res.HasStalledJobs ? "[Stalled Jobs Detected]" : "[Queue Clean]")}";
        Logger?.LogInfo(nameof(ConnectivityViewModel), LastPrinterStatus);
        return Task.CompletedTask;
    });

    private void OpenAdapterEditPopup(object? parameter)
    {
        if (parameter is NetworkAdapterInfo adapter)
        {
            SelectedAdapter = adapter;
        }

        var target = SelectedAdapter ?? AvailableAdapters.FirstOrDefault();
        if (target != null)
        {
            SelectedAdapter = target;
            SelectedEditingAdapter = target;
            AdapterUseDhcpIp = target.DhcpEnabled;
            AdapterStaticIp = target.IpAddresses.FirstOrDefault() ?? "192.168.1.100";
            AdapterSubnetMask = target.SubnetMask ?? "255.255.255.0";
            AdapterDefaultGateway = target.DefaultGateway ?? "192.168.1.1";
            AdapterUseDhcpDns = target.DhcpEnabled;
            AdapterPreferredDns = target.DnsServers?.FirstOrDefault() ?? "1.1.1.1";
            AdapterAlternateDns = target.DnsServers?.Skip(1).FirstOrDefault() ?? "8.8.8.8";
            AdapterMtu = target.Mtu ?? 1500;
            IsAdapterEditPopupOpen = true;
            Logger?.LogInfo(nameof(ConnectivityViewModel), $"Opened adapter edit popup for '{target.Name}'.");
        }
    }

    private void CloseAdapterEditPopup()
    {
        IsAdapterEditPopupOpen = false;
        SelectedEditingAdapter = null;
        Logger?.LogInfo(nameof(ConnectivityViewModel), "Closed adapter edit popup.");
    }

    private async Task SaveAdapterIpConfigAsync()
    {
        if (SelectedEditingAdapter == null) return;
        string name = SelectedEditingAdapter.Name;
        await ExecuteAsync($"Configure IP for '{name}'", async () =>
        {
            var config = new AdapterIpConfig(AdapterUseDhcpIp, AdapterStaticIp, AdapterSubnetMask, AdapterDefaultGateway);
            bool ok = _connectivityService.SetAdapterIpConfiguration(name, config);
            await RefreshAdaptersAsync();
            LastNetworkStatus = ok
                ? $"IP configuration for '{name}' updated successfully (UseDhcp={config.UseDhcp})."
                : $"Failed to update IP configuration for '{name}'.";
        });
    }

    private async Task SaveAdapterDnsConfigAsync()
    {
        if (SelectedEditingAdapter == null) return;
        string name = SelectedEditingAdapter.Name;
        await ExecuteAsync($"Configure DNS for '{name}'", async () =>
        {
            var config = new AdapterDnsConfig(AdapterUseDhcpDns, AdapterPreferredDns, AdapterAlternateDns);
            bool ok = _connectivityService.SetAdapterDnsConfiguration(name, config);
            await RefreshAdaptersAsync();
            LastNetworkStatus = ok
                ? $"DNS configuration for '{name}' updated successfully (UseDhcp={config.UseDhcp})."
                : $"Failed to update DNS configuration for '{name}'.";
        });
    }

    private async Task SetAdapterMtuAsync()
    {
        if (SelectedEditingAdapter == null) return;
        string name = SelectedEditingAdapter.Name;
        await ExecuteAsync($"Set MTU for '{name}'", async () =>
        {
            bool ok = _connectivityService.SetAdapterMtu(name, AdapterMtu);
            await RefreshAdaptersAsync();
            LastNetworkStatus = ok
                ? $"MTU for '{name}' set to {AdapterMtu} successfully."
                : $"Failed to set MTU for '{name}'.";
        });
    }

    private async Task ToggleAdapterEnableAsync()
    {
        if (SelectedEditingAdapter == null) return;
        string name = SelectedEditingAdapter.Name;
        bool isCurrentlyUp = string.Equals(SelectedEditingAdapter.Status, "Up", StringComparison.OrdinalIgnoreCase);
        await ExecuteAsync($"{(isCurrentlyUp ? "Disable" : "Enable")} Adapter '{name}'", async () =>
        {
            bool ok = isCurrentlyUp
                ? _connectivityService.DisableAdapter(name)
                : _connectivityService.EnableAdapter(name);
            await RefreshAdaptersAsync();
            LastNetworkStatus = ok
                ? $"Adapter '{name}' {(isCurrentlyUp ? "disabled" : "enabled")} successfully."
                : $"Failed to {(isCurrentlyUp ? "disable" : "enable")} adapter '{name}'.";
        });
    }

    private async Task RenewAdapterDhcpAsync()
    {
        if (SelectedEditingAdapter == null) return;
        string name = SelectedEditingAdapter.Name;
        await ExecuteAsync($"Renew DHCP for '{name}'", async () =>
        {
            bool ok = _connectivityService.ReleaseRenewAdapterDhcp(name);
            await RefreshAdaptersAsync();
            LastNetworkStatus = ok
                ? $"DHCP lease for '{name}' renewed successfully."
                : $"Failed to renew DHCP lease for '{name}'.";
        });
    }

    public async Task RefreshPrintersAsync()
    {
        try
        {
            Logger?.LogInfo(nameof(ConnectivityViewModel), "Scanning installed printers...");
            var printers = await Task.Run(() => _printerService.GetPrinters()?.ToList() ?? new List<PrinterInfo>());
            AvailablePrinters.Clear();
            foreach (var p in printers)
            {
                AvailablePrinters.Add(p);
            }

            if (SelectedPrinter == null && AvailablePrinters.Count > 0)
            {
                var def = AvailablePrinters.FirstOrDefault(p => p.IsDefault);
                SelectedPrinter = def ?? AvailablePrinters[0];
            }

            LastPrinterStatus = $"Discovered {AvailablePrinters.Count} installed printer(s). Active: {SelectedPrinter?.Name ?? "None"}";
            Logger?.LogInfo(nameof(ConnectivityViewModel), LastPrinterStatus);
        }
        catch (Exception ex)
        {
            LastPrinterStatus = $"Printer discovery failed: {ex.Message}";
            Logger?.LogError(nameof(ConnectivityViewModel), LastPrinterStatus);
        }
    }

    private void OpenPrinterEditPopup(object? parameter)
    {
        if (parameter is PrinterInfo printer)
        {
            SelectedPrinter = printer;
        }

        var target = SelectedPrinter ?? AvailablePrinters.FirstOrDefault();
        if (target != null)
        {
            SelectedPrinter = target;
            SelectedEditingPrinter = target;
            IsPrinterEditPopupOpen = true;
            Logger?.LogInfo(nameof(ConnectivityViewModel), $"Opened printer edit popup for '{target.Name}'.");
        }
    }

    private void ClosePrinterEditPopup()
    {
        IsPrinterEditPopupOpen = false;
        SelectedEditingPrinter = null;
        Logger?.LogInfo(nameof(ConnectivityViewModel), "Closed printer edit popup.");
    }

    private async Task PrintTestPageAsync()
    {
        if (SelectedEditingPrinter == null) return;
        string name = SelectedEditingPrinter.Name;
        await ExecuteAsync($"Print Test Page to '{name}'", () =>
        {
            bool ok = _printerService.PrintTestPage(name);
            LastPrinterStatus = ok
                ? $"Test page sent to printer '{name}' successfully."
                : $"Failed to send test page to printer '{name}'.";
            return Task.CompletedTask;
        });
    }

    private async Task PurgeTargetPrinterQueueAsync()
    {
        if (SelectedEditingPrinter == null) return;
        string name = SelectedEditingPrinter.Name;
        await ExecuteAsync($"Purge Queue for '{name}'", async () =>
        {
            bool ok = _printerService.PurgePrinterQueue(name);
            await RefreshPrintersAsync();
            LastPrinterStatus = ok
                ? $"Print queue for printer '{name}' purged successfully."
                : $"Failed to purge print queue for printer '{name}'.";
        });
    }

    private async Task SetAsDefaultPrinterAsync()
    {
        if (SelectedEditingPrinter == null) return;
        string name = SelectedEditingPrinter.Name;
        await ExecuteAsync($"Set '{name}' as Default", async () =>
        {
            bool ok = _printerService.SetDefaultPrinter(name);
            await RefreshPrintersAsync();
            LastPrinterStatus = ok
                ? $"Printer '{name}' set as default successfully."
                : $"Failed to set printer '{name}' as default.";
        });
    }

    private async Task ResetTargetPrinterConnectionAsync()
    {
        if (SelectedEditingPrinter == null) return;
        string name = SelectedEditingPrinter.Name;
        await ExecuteAsync($"Reset Connection for '{name}'", async () =>
        {
            var res = _printerService.ResetPrinterConnection(name);
            await RefreshPrintersAsync();
            LastPrinterStatus = res.Success
                ? $"Reset connection for '{name}': {res.ReconnectedPrinters} reconnected, {res.RemovedStalePrinters} stale removed."
                : $"Reset connection failed for '{name}': {res.Message}";
        });
    }
}
