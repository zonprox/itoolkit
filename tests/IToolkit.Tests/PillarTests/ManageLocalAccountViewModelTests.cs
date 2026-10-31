namespace IToolkit.Tests.PillarTests;

using System;
using System.Threading.Tasks;
using IToolkit.App.ViewModels;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Models;
using IToolkit.Core.Services.Identity;
using Moq;
using Xunit;

public class ManageLocalAccountViewModelTests
{
    private readonly Mock<IIdentityService> _identityMock;
    private readonly Mock<ISafetyConfirmationService> _confirmationMock;
    private readonly Mock<IBackupService> _backupMock;
    private readonly Mock<IDialogService> _dialogMock;
    private readonly Mock<IActivityLogger> _loggerMock;

    public ManageLocalAccountViewModelTests()
    {
        _identityMock = new Mock<IIdentityService>();
        _confirmationMock = new Mock<ISafetyConfirmationService>();
        _backupMock = new Mock<IBackupService>();
        _dialogMock = new Mock<IDialogService>();
        _loggerMock = new Mock<IActivityLogger>();
    }

    [Fact]
    public async Task UnlockCommand_ExecutesOnlyForTargetEntity()
    {
        var alice = new LocalAccountItem("Alice", "S-1-5-21-1001", true, true, false, false);
        _identityMock.Setup(s => s.UnlockLocalAccount("Alice")).Returns(true);

        var vm = new ManageLocalAccountViewModel(
            alice,
            _identityMock.Object,
            _confirmationMock.Object,
            _backupMock.Object,
            _dialogMock.Object,
            _loggerMock.Object);

        await vm.UnlockCommand.ExecuteAsync(null);

        _identityMock.Verify(s => s.UnlockLocalAccount("Alice"), Times.Once);
        _identityMock.Verify(s => s.UnlockLocalAccount("Bob"), Times.Never);
        Assert.False(vm.IsLocked);
        Assert.Contains("completed successfully", vm.StatusMessage);
    }

    [Fact]
    public async Task ToggleEnabledCommand_ExecutesOnlyForTargetEntity()
    {
        var alice = new LocalAccountItem("Alice", "S-1-5-21-1001", true, false, false, false);
        _identityMock.Setup(s => s.SetAccountEnabled("Alice", false)).Returns(true);

        var vm = new ManageLocalAccountViewModel(
            alice,
            _identityMock.Object,
            _confirmationMock.Object,
            _backupMock.Object,
            _dialogMock.Object,
            _loggerMock.Object);

        await vm.ToggleEnabledCommand.ExecuteAsync(null);

        _identityMock.Verify(s => s.SetAccountEnabled("Alice", false), Times.Once);
        _identityMock.Verify(s => s.SetAccountEnabled("Bob", It.IsAny<bool>()), Times.Never);
        Assert.False(vm.IsEnabled);
        Assert.Contains("completed successfully", vm.StatusMessage);
    }

    [Fact]
    public async Task ResetPasswordCommand_ExecutesOnlyForTargetEntity()
    {
        var alice = new LocalAccountItem("Alice", "S-1-5-21-1001", true, false, false, false);
        _identityMock.Setup(s => s.ResetUserPassword("Alice", "P@ssword123!")).Returns(true);

        var vm = new ManageLocalAccountViewModel(
            alice,
            _identityMock.Object,
            _confirmationMock.Object,
            _backupMock.Object,
            _dialogMock.Object,
            _loggerMock.Object)
        {
            NewPassword = "P@ssword123!"
        };

        await vm.ResetPasswordCommand.ExecuteAsync(null);

        _identityMock.Verify(s => s.ResetUserPassword("Alice", "P@ssword123!"), Times.Once);
        _identityMock.Verify(s => s.ResetUserPassword("Bob", It.IsAny<string>()), Times.Never);
        Assert.Equal(string.Empty, vm.NewPassword);
        Assert.Contains("completed successfully", vm.StatusMessage);
    }

    [Fact]
    public async Task RemoveAccountCommand_InvokesSafetyGate_AndRemovesOnlyTargetEntity()
    {
        var alice = new LocalAccountItem("Alice", "S-1-5-21-1001", true, false, false, false);
        _confirmationMock
            .Setup(c => c.ConfirmAsync(It.IsAny<string>(), It.Is<string>(m => m.Contains("Alice")), It.IsAny<string>()))
            .ReturnsAsync(true);
        _identityMock.Setup(s => s.RemoveLocalAccount("Alice", "S-1-5-21-1001")).Returns(true);

        bool closeRequested = false;
        var vm = new ManageLocalAccountViewModel(
            alice,
            _identityMock.Object,
            _confirmationMock.Object,
            _backupMock.Object,
            _dialogMock.Object,
            _loggerMock.Object);
        vm.RequestClose += () => closeRequested = true;

        await vm.RemoveAccountCommand.ExecuteAsync(null);

        _confirmationMock.Verify(c => c.ConfirmAsync(It.IsAny<string>(), It.Is<string>(m => m.Contains("Alice")), It.IsAny<string>()), Times.Once);
        _identityMock.Verify(s => s.RemoveLocalAccount("Alice", "S-1-5-21-1001"), Times.Once);
        _identityMock.Verify(s => s.RemoveLocalAccount("Bob", It.IsAny<string>()), Times.Never);
        Assert.True(vm.IsAccountRemoved);
        Assert.True(closeRequested);
    }

    [Fact]
    public async Task RemoveAccountCommand_WhenConfirmationDenied_AbortsWithoutRemoving()
    {
        var alice = new LocalAccountItem("Alice", "S-1-5-21-1001", true, false, false, false);
        _confirmationMock
            .Setup(c => c.ConfirmAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>()))
            .ReturnsAsync(false);

        var vm = new ManageLocalAccountViewModel(
            alice,
            _identityMock.Object,
            _confirmationMock.Object,
            _backupMock.Object,
            _dialogMock.Object,
            _loggerMock.Object);

        await vm.RemoveAccountCommand.ExecuteAsync(null);

        _identityMock.Verify(s => s.RemoveLocalAccount(It.IsAny<string>(), It.IsAny<string>()), Times.Never);
        Assert.False(vm.IsAccountRemoved);
        Assert.Contains("cancelled by user", vm.StatusMessage);
    }

    [Fact]
    public async Task RemoveAccountCommand_WhenBuiltInAdmin_IsBlockedImmediately()
    {
        var admin = new LocalAccountItem("Administrator", "S-1-5-21-500", true, false, true, true);

        var vm = new ManageLocalAccountViewModel(
            admin,
            _identityMock.Object,
            _confirmationMock.Object,
            _backupMock.Object,
            _dialogMock.Object,
            _loggerMock.Object);

        Assert.False(vm.RemoveAccountCommand.CanExecute(null));

        await vm.RemoveAccountCommand.ExecuteAsync(null);

        _confirmationMock.Verify(c => c.ConfirmAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<string>()), Times.Never);
        _identityMock.Verify(s => s.RemoveLocalAccount(It.IsAny<string>(), It.IsAny<string>()), Times.Never);
    }

    [Fact]
    public async Task NonInterference_MutationsOnAliceDoNotTouchBob()
    {
        var alice = new LocalAccountItem("Alice", "S-1-5-21-1001", true, true, false, false);
        var bob = new LocalAccountItem("Bob", "S-1-5-21-1002", true, true, false, false);

        _identityMock.Setup(s => s.UnlockLocalAccount("Alice")).Returns(true);
        _identityMock.Setup(s => s.SetAccountEnabled("Alice", false)).Returns(true);
        _identityMock.Setup(s => s.ResetUserPassword("Alice", "AliceSecret!")).Returns(true);

        var vmAlice = new ManageLocalAccountViewModel(
            alice,
            _identityMock.Object,
            _confirmationMock.Object,
            _backupMock.Object,
            _dialogMock.Object,
            _loggerMock.Object);

        var vmBob = new ManageLocalAccountViewModel(
            bob,
            _identityMock.Object,
            _confirmationMock.Object,
            _backupMock.Object,
            _dialogMock.Object,
            _loggerMock.Object);

        // Perform mutations on Alice
        await vmAlice.UnlockCommand.ExecuteAsync(null);
        await vmAlice.ToggleEnabledCommand.ExecuteAsync(null);
        vmAlice.NewPassword = "AliceSecret!";
        await vmAlice.ResetPasswordCommand.ExecuteAsync(null);

        // Verify Alice's ViewModel state updated
        Assert.False(vmAlice.IsLocked);
        Assert.False(vmAlice.IsEnabled);

        // Verify Bob's ViewModel state is completely untouched
        Assert.True(vmBob.IsLocked);
        Assert.True(vmBob.IsEnabled);
        Assert.Equal(string.Empty, vmBob.NewPassword);

        // Verify backend was called exclusively for Alice
        _identityMock.Verify(s => s.UnlockLocalAccount("Alice"), Times.Once);
        _identityMock.Verify(s => s.SetAccountEnabled("Alice", false), Times.Once);
        _identityMock.Verify(s => s.ResetUserPassword("Alice", "AliceSecret!"), Times.Once);

        _identityMock.Verify(s => s.UnlockLocalAccount("Bob"), Times.Never);
        _identityMock.Verify(s => s.SetAccountEnabled("Bob", It.IsAny<bool>()), Times.Never);
        _identityMock.Verify(s => s.ResetUserPassword("Bob", It.IsAny<string>()), Times.Never);
    }

    [Fact]
    public async Task BackupUserCommand_TargetsOnlyTargetUser()
    {
        var alice = new LocalAccountItem("Alice", "S-1-5-21-1001", true, false, false, false);
        _backupMock
            .Setup(b => b.GetUserProfileMap("Alice"))
            .Returns(new UserProfileMap(
                "Alice",
                @"C:\Users\Alice",
                @"C:\Users\Alice\Desktop",
                @"C:\Users\Alice\Documents",
                @"C:\Users\Alice\Downloads",
                @"C:\Users\Alice\Favorites",
                @"C:\Users\Alice\Pictures",
                false));

        _backupMock
            .Setup(b => b.RunRobocopySync(@"C:\Users\Alice", @"E:\Backups\Alice", false))
            .Returns(new RobocopySyncResult(@"C:\Users\Alice", @"E:\Backups\Alice", 1, true, "OK"));

        var vm = new ManageLocalAccountViewModel(
            alice,
            _identityMock.Object,
            _confirmationMock.Object,
            _backupMock.Object,
            _dialogMock.Object,
            _loggerMock.Object)
        {
            BackupDestinationDirectory = @"E:\Backups\Alice"
        };

        await vm.BackupUserCommand.ExecuteAsync(null);

        _backupMock.Verify(b => b.GetUserProfileMap("Alice"), Times.Once);
        _backupMock.Verify(b => b.GetUserProfileMap("Bob"), Times.Never);
        _backupMock.Verify(b => b.RunRobocopySync(@"C:\Users\Alice", @"E:\Backups\Alice", false), Times.Once);
        Assert.Contains("completed successfully", vm.StatusMessage);
    }
}
