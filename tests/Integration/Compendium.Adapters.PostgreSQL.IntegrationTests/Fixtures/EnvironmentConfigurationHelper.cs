// -----------------------------------------------------------------------
// <copyright file="EnvironmentConfigurationHelper.cs" company="Sassy Solutions">
//     Copyright (c) 2026 Sassy Solutions. Licensed under the MIT License.
// </copyright>
// -----------------------------------------------------------------------

namespace Compendium.IntegrationTests.Infrastructure;

/// <summary>
/// Helper for managing PostgreSQL test infrastructure configuration with fallback strategy:
/// 1. Environment variable (CI/CD or manual override)
/// 2. Docker Compose local (localhost)
/// 3. TestContainers (automatic, used when above are unavailable)
/// </summary>
public static class EnvironmentConfigurationHelper
{
    /// <summary>
    /// Gets the PostgreSQL connection string using fallback strategy. Returns empty
    /// when no external PostgreSQL is available — the caller should fall back to
    /// TestContainers.
    /// </summary>
    public static string GetPostgreSqlConnectionString()
    {
        var envConnectionString = Environment.GetEnvironmentVariable("EVENTSTORE_CONNECTION_STRING");
        if (!string.IsNullOrEmpty(envConnectionString))
        {
            Console.WriteLine("✅ Using PostgreSQL from environment variable");
            return envConnectionString;
        }

        var dockerConnectionString = "Host=localhost;Database=compendium;Username=compendium_user;Password=compendium_password;Port=5432;Timeout=30;Command Timeout=30";
        if (IsPostgreSqlAvailable(dockerConnectionString))
        {
            Console.WriteLine("✅ Using PostgreSQL from Docker Compose (localhost:5432)");
            return dockerConnectionString;
        }

        Console.WriteLine("⚠️ No local PostgreSQL found. TestContainers will be used.");
        return string.Empty;
    }

    private static bool IsPostgreSqlAvailable(string connectionString)
    {
        try
        {
            using var connection = new Npgsql.NpgsqlConnection(connectionString);
            connection.Open();
            connection.Close();
            return true;
        }
        catch
        {
            return false;
        }
    }
}
