namespace IToolkit.Tests.SafetyTests;

using Moq;
using IToolkit.Core.Abstractions;
using IToolkit.Core.Safety;
using Xunit;

public class ElevationGuardTests
{
    [Fact]
    public void AssertElevated_WhenUnelevated_ThrowsUnauthorizedAccessExceptionWithOperationName()
    {
        // Arrange
        var mockElevation = new Mock<IElevationService>();
        mockElevation.Setup(m => m.IsElevated()).Returns(false);
        // Ensure default AssertElevated behavior if not overridden
        mockElevation.Setup(m => m.AssertElevated(It.IsAny<string>()))
            .Callback<string>(op => throw new UnauthorizedAccessException(
                $"Administrative privileges are required to perform '{op}'. Please restart IToolkit as Administrator."));

        var guard = new ElevationGuard(mockElevation.Object);

        // Act & Assert
        var ex = Assert.Throws<UnauthorizedAccessException>(() =>
            guard.AssertElevated("Purge Component Store"));

        Assert.Contains("Purge Component Store", ex.Message);
        Assert.Contains("Administrative privileges are required", ex.Message);
        Assert.Contains("Administrator", ex.Message);
    }

    [Fact]
    public void AssertElevated_WhenElevated_SucceedsWithoutException()
    {
        // Arrange
        var mockElevation = new Mock<IElevationService>();
        mockElevation.Setup(m => m.IsElevated()).Returns(true);
        mockElevation.Setup(m => m.AssertElevated(It.IsAny<string>())); // No throw

        var guard = new ElevationGuard(mockElevation.Object);

        // Act & Assert (does not throw)
        guard.AssertElevated("Repair Windows Update");
        mockElevation.Verify(m => m.AssertElevated("Repair Windows Update"), Times.Once);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void IsElevated_DelegatesToUnderlyingService(bool simulatedElevated)
    {
        // Arrange
        var mockElevation = new Mock<IElevationService>();
        mockElevation.Setup(m => m.IsElevated()).Returns(simulatedElevated);

        var guard = new ElevationGuard(mockElevation.Object);

        // Act
        bool result = guard.IsElevated();

        // Assert
        Assert.Equal(simulatedElevated, result);
        mockElevation.Verify(m => m.IsElevated(), Times.Once);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void RestartElevated_DelegatesToUnderlyingService(bool restartSuccess)
    {
        // Arrange
        var mockElevation = new Mock<IElevationService>();
        mockElevation.Setup(m => m.RestartElevated()).Returns(restartSuccess);

        var guard = new ElevationGuard(mockElevation.Object);

        // Act
        bool result = guard.RestartElevated();

        // Assert
        Assert.Equal(restartSuccess, result);
        mockElevation.Verify(m => m.RestartElevated(), Times.Once);
    }
}
