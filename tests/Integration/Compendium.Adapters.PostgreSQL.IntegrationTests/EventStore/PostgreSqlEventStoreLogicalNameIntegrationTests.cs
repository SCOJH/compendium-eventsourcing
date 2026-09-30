// -----------------------------------------------------------------------
// <copyright file="PostgreSqlEventStoreLogicalNameIntegrationTests.cs" company="Sassy Solutions">
//     Copyright (c) 2026 Sassy Solutions. Licensed under the MIT License.
//     See LICENSE in the project root for license information.
// </copyright>
// -----------------------------------------------------------------------

using Compendium.Adapters.PostgreSQL.Configuration;
using Compendium.Adapters.PostgreSQL.EventStore;
using Compendium.Core.Domain.Events;
using Compendium.Core.EventSourcing;
using Compendium.Core.EventSourcing.Attributes;
using Compendium.IntegrationTests.Fixtures;
using AwesomeAssertions;
using Dapper;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using Npgsql;
using NSubstitute;
using Xunit;

namespace Compendium.IntegrationTests.EventStore;

/// <summary>
/// Round trip, against a real PostgreSQL, of the name written in the <c>event_type</c> column.
/// <para>
/// The store asks the <see cref="IEventTypeRegistry"/> port for the logical name of each appended
/// event. The three append strategies are distinct code paths chosen by batch size — standard
/// INSERT below 10 events, batched INSERT from 10, binary COPY from 500 — so each is exercised.
/// </para>
/// <para>
/// Reading goes through the real <see cref="SecureEventDeserializer"/> over the real
/// <see cref="EventTypeRegistry"/>, which indexes a type under both its logical and its assembly
/// qualified name: that is what keeps rows written before this change readable, and it is only
/// observable end to end here.
/// </para>
/// </summary>
public sealed class PostgreSqlEventStoreLogicalNameIntegrationTests : IClassFixture<PostgreSqlFixture>, IAsyncLifetime
{
    private const string TableName = "event_store_logical_name_test";
    private const string LogicalName = "IntegrationTests.OrderPlaced";

    private readonly PostgreSqlFixture _pg;
    private readonly EventTypeRegistry _registry = new();
    private PostgreSqlEventStore? _namingStore;
    private PostgreSqlEventStore? _legacyStore;

    public PostgreSqlEventStoreLogicalNameIntegrationTests(PostgreSqlFixture pg)
    {
        _pg = pg;
    }

    public async Task InitializeAsync()
    {
        if (!_pg.IsAvailable)
        {
            return;
        }

        _registry.RegisterEventTypes(new[] { typeof(DecoratedEvent), typeof(UndecoratedEvent) });
        var deserializer = new SecureEventDeserializer(_registry);
        var options = Options.Create(_pg.GetOptions(TableName));

        // The store as wired by AddPostgreSqlEventStore: it knows the registry, so it writes logical names.
        _namingStore = new PostgreSqlEventStore(
            options,
            deserializer,
            Substitute.For<ILogger<PostgreSqlEventStore>>(),
            eventTypeRegistry: _registry);

        // A store without registry writes the assembly qualified name — byte for byte what every
        // version of this adapter wrote before logical names. It stands in for rows already on disk.
        _legacyStore = new PostgreSqlEventStore(
            options,
            deserializer,
            Substitute.For<ILogger<PostgreSqlEventStore>>());

        (await _namingStore.InitializeSchemaAsync()).IsSuccess.Should().BeTrue();
    }

    public async Task DisposeAsync()
    {
        if (_namingStore != null)
        {
            await _namingStore.DisposeAsync();
        }

        if (_legacyStore != null)
        {
            await _legacyStore.DisposeAsync();
        }

        _registry.Dispose();
    }

    [RequiresDockerFact]
    public Task AppendEventsAsync_OneEvent_StandardInsert_WritesTheLogicalName() =>
        AssertDecoratedEventsAreStoredUnderTheirLogicalNameAsync(eventCount: 1);

    [RequiresDockerFact]
    public Task AppendEventsAsync_TenEvents_BatchedInsert_WritesTheLogicalName() =>
        AssertDecoratedEventsAreStoredUnderTheirLogicalNameAsync(eventCount: 10);

    [RequiresDockerFact]
    public Task AppendEventsAsync_FiveHundredEvents_Copy_WritesTheLogicalName() =>
        AssertDecoratedEventsAreStoredUnderTheirLogicalNameAsync(eventCount: 500);

    [RequiresDockerFact]
    public async Task AppendEventsAsync_UndecoratedEvent_KeepsWritingTheAssemblyQualifiedName()
    {
        // Arrange
        EnsureDatabase();
        var streamId = Guid.NewGuid().ToString();
        var events = new List<IDomainEvent> { Undecorated(streamId, 1) };

        // Act
        var append = await _namingStore!.AppendEventsAsync(streamId, events, 0);

        // Assert — a consumer that adopts no attribute sees no difference in what is written.
        append.IsSuccess.Should().BeTrue();
        (await StoredEventTypesAsync(streamId))
            .Should().Equal(typeof(UndecoratedEvent).AssemblyQualifiedName);
    }

    [RequiresDockerFact]
    public async Task GetEventsAsync_StreamMixingAssemblyQualifiedAndLogicalNames_IsReadBackWhole()
    {
        // Arrange — two rows as every earlier version wrote them, then one as this version writes it.
        EnsureDatabase();
        var streamId = Guid.NewGuid().ToString();
        var aqn = typeof(DecoratedEvent).AssemblyQualifiedName!;

        (await _legacyStore!.AppendEventsAsync(streamId, new List<IDomainEvent> { Decorated(streamId, 1), Decorated(streamId, 2) }, 0))
            .IsSuccess.Should().BeTrue();
        (await _namingStore!.AppendEventsAsync(streamId, new List<IDomainEvent> { Decorated(streamId, 3) }, 2))
            .IsSuccess.Should().BeTrue();

        (await StoredEventTypesAsync(streamId)).Should().Equal(aqn, aqn, LogicalName);

        // Act
        var read = await _namingStore.GetEventsAsync(streamId);

        // Assert — one binary reads both forms, in order, as a success carrying every event.
        read.IsSuccess.Should().BeTrue(read.IsFailure ? read.Error.Message : string.Empty);
        read.Value.Should().HaveCount(3);
        read.Value.Should().AllBeOfType<DecoratedEvent>();
        read.Value.Select(e => e.AggregateVersion).Should().Equal(1L, 2L, 3L);

        // And nothing was rewritten: the rows written under the old name keep it.
        (await StoredEventTypesAsync(streamId)).Should().Equal(aqn, aqn, LogicalName);
    }

    private async Task AssertDecoratedEventsAreStoredUnderTheirLogicalNameAsync(int eventCount)
    {
        // Arrange
        EnsureDatabase();
        var streamId = Guid.NewGuid().ToString();
        var events = Enumerable.Range(1, eventCount)
            .Select(i => (IDomainEvent)Decorated(streamId, i))
            .ToList();

        // Act
        var append = await _namingStore!.AppendEventsAsync(streamId, events, 0);

        // Assert — what is written is the name the port gives, never the assembly qualified name.
        append.IsSuccess.Should().BeTrue(append.IsFailure ? append.Error.Message : string.Empty);
        var storedTypes = await StoredEventTypesAsync(streamId);
        storedTypes.Should().HaveCount(eventCount);
        storedTypes.Should().OnlyContain(t => t == LogicalName);

        // And it reads back whole through the registry.
        var read = await _namingStore.GetEventsAsync(streamId);
        read.IsSuccess.Should().BeTrue(read.IsFailure ? read.Error.Message : string.Empty);
        read.Value.Should().HaveCount(eventCount);
        read.Value.Should().AllBeOfType<DecoratedEvent>();
    }

    private void EnsureDatabase()
    {
        // RequiresDockerFact already skips without Docker; if Docker is there, a missing database
        // is a failure to report, not a reason to pass without asserting anything.
        _pg.IsAvailable.Should().BeTrue(_pg.UnavailableReason);
    }

    private async Task<IReadOnlyList<string>> StoredEventTypesAsync(string streamId)
    {
        await using var connection = new NpgsqlConnection(_pg.ConnectionString);
        await connection.OpenAsync();

        var types = await connection.QueryAsync<string>(
            $"SELECT event_type FROM {TableName} WHERE stream_id = @StreamId ORDER BY version",
            new { StreamId = streamId });

        return types.ToList();
    }

    private static DecoratedEvent Decorated(string streamId, long version) => new()
    {
        EventId = Guid.NewGuid(),
        AggregateId = streamId,
        AggregateType = "Order",
        OccurredOn = DateTimeOffset.UtcNow,
        AggregateVersion = version,
        Data = $"Event {version}"
    };

    private static UndecoratedEvent Undecorated(string streamId, long version) => new()
    {
        EventId = Guid.NewGuid(),
        AggregateId = streamId,
        AggregateType = "Order",
        OccurredOn = DateTimeOffset.UtcNow,
        AggregateVersion = version
    };

    [EventTypeName(LogicalName)]
    private sealed class DecoratedEvent : IDomainEvent
    {
        public Guid EventId { get; init; }
        public string AggregateId { get; init; } = string.Empty;
        public string AggregateType { get; init; } = string.Empty;
        public DateTimeOffset OccurredOn { get; init; }
        public long AggregateVersion { get; init; }
        public int EventVersion { get; init; } = 1;
        public string Data { get; init; } = string.Empty;
    }

    private sealed class UndecoratedEvent : IDomainEvent
    {
        public Guid EventId { get; init; }
        public string AggregateId { get; init; } = string.Empty;
        public string AggregateType { get; init; } = string.Empty;
        public DateTimeOffset OccurredOn { get; init; }
        public long AggregateVersion { get; init; }
        public int EventVersion { get; init; } = 1;
    }
}
