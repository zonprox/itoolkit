namespace IToolkit.Tests.SafetyTests;

using IToolkit.Core.Safety;
using Xunit;

public class ElevationGuardEmpiricalChallengeTests
{
    [Fact]
    public void ElevationGuard_WhenNoUnderlyingService_RespectsSimulateAdminEnvVar()
    {
        string? originalEnv = Environment.GetEnvironmentVariable("ITOOLKIT_SIMULATE_ADMIN");
        try
        {
            // When ITOOLKIT_SIMULATE_ADMIN is "1", it should report elevated
            Environment.SetEnvironmentVariable("ITOOLKIT_SIMULATE_ADMIN", "1");
            var guard = new ElevationGuard(null);
            Assert.True(guard.IsElevated());
            // AssertElevated should not throw
            guard.AssertElevated("Simulated Operation");

            // When ITOOLKIT_SIMULATE_ADMIN is "0" (assuming non-root process)
            Environment.SetEnvironmentVariable("ITOOLKIT_SIMULATE_ADMIN", "0");
            var guardUnelevated = new ElevationGuard(null);
            // In a standard non-root Linux container:
            if (!guardUnelevated.IsElevated())
            {
                var ex = Assert.Throws<UnauthorizedAccessException>(() =>
                    guardUnelevated.AssertElevated("Restricted Operation"));
                Assert.Contains("Restricted Operation", ex.Message);
            }
        }
        finally
        {
            Environment.SetEnvironmentVariable("ITOOLKIT_SIMULATE_ADMIN", originalEnv);
        }
    }
}
