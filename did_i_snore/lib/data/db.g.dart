// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'db.dart';

// ignore_for_file: type=lint
class $EventsTable extends Events with TableInfo<$EventsTable, Event> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $EventsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _startedAtMeta = const VerificationMeta(
    'startedAt',
  );
  @override
  late final GeneratedColumn<int> startedAt = GeneratedColumn<int>(
    'started_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _endedAtMeta = const VerificationMeta(
    'endedAt',
  );
  @override
  late final GeneratedColumn<int> endedAt = GeneratedColumn<int>(
    'ended_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _durationMsMeta = const VerificationMeta(
    'durationMs',
  );
  @override
  late final GeneratedColumn<int> durationMs = GeneratedColumn<int>(
    'duration_ms',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _schemaVersionMeta = const VerificationMeta(
    'schemaVersion',
  );
  @override
  late final GeneratedColumn<int> schemaVersion = GeneratedColumn<int>(
    'schema_version',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(1),
  );
  static const VerificationMeta _stateMeta = const VerificationMeta('state');
  @override
  late final GeneratedColumn<String> state = GeneratedColumn<String>(
    'state',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('pending'),
  );
  static const VerificationMeta _topLabelMeta = const VerificationMeta(
    'topLabel',
  );
  @override
  late final GeneratedColumn<String> topLabel = GeneratedColumn<String>(
    'top_label',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _labelsJsonMeta = const VerificationMeta(
    'labelsJson',
  );
  @override
  late final GeneratedColumn<String> labelsJson = GeneratedColumn<String>(
    'labels_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _audioPathMeta = const VerificationMeta(
    'audioPath',
  );
  @override
  late final GeneratedColumn<String> audioPath = GeneratedColumn<String>(
    'audio_path',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _peaksPathMeta = const VerificationMeta(
    'peaksPath',
  );
  @override
  late final GeneratedColumn<String> peaksPath = GeneratedColumn<String>(
    'peaks_path',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _starredMeta = const VerificationMeta(
    'starred',
  );
  @override
  late final GeneratedColumn<bool> starred = GeneratedColumn<bool>(
    'starred',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("starred" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _userLabelMeta = const VerificationMeta(
    'userLabel',
  );
  @override
  late final GeneratedColumn<String> userLabel = GeneratedColumn<String>(
    'user_label',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<int> deletedAt = GeneratedColumn<int>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    startedAt,
    endedAt,
    durationMs,
    createdAt,
    schemaVersion,
    state,
    topLabel,
    labelsJson,
    audioPath,
    peaksPath,
    starred,
    userLabel,
    deletedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'events';
  @override
  VerificationContext validateIntegrity(
    Insertable<Event> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('started_at')) {
      context.handle(
        _startedAtMeta,
        startedAt.isAcceptableOrUnknown(data['started_at']!, _startedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_startedAtMeta);
    }
    if (data.containsKey('ended_at')) {
      context.handle(
        _endedAtMeta,
        endedAt.isAcceptableOrUnknown(data['ended_at']!, _endedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_endedAtMeta);
    }
    if (data.containsKey('duration_ms')) {
      context.handle(
        _durationMsMeta,
        durationMs.isAcceptableOrUnknown(data['duration_ms']!, _durationMsMeta),
      );
    } else if (isInserting) {
      context.missing(_durationMsMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('schema_version')) {
      context.handle(
        _schemaVersionMeta,
        schemaVersion.isAcceptableOrUnknown(
          data['schema_version']!,
          _schemaVersionMeta,
        ),
      );
    }
    if (data.containsKey('state')) {
      context.handle(
        _stateMeta,
        state.isAcceptableOrUnknown(data['state']!, _stateMeta),
      );
    }
    if (data.containsKey('top_label')) {
      context.handle(
        _topLabelMeta,
        topLabel.isAcceptableOrUnknown(data['top_label']!, _topLabelMeta),
      );
    }
    if (data.containsKey('labels_json')) {
      context.handle(
        _labelsJsonMeta,
        labelsJson.isAcceptableOrUnknown(data['labels_json']!, _labelsJsonMeta),
      );
    }
    if (data.containsKey('audio_path')) {
      context.handle(
        _audioPathMeta,
        audioPath.isAcceptableOrUnknown(data['audio_path']!, _audioPathMeta),
      );
    } else if (isInserting) {
      context.missing(_audioPathMeta);
    }
    if (data.containsKey('peaks_path')) {
      context.handle(
        _peaksPathMeta,
        peaksPath.isAcceptableOrUnknown(data['peaks_path']!, _peaksPathMeta),
      );
    }
    if (data.containsKey('starred')) {
      context.handle(
        _starredMeta,
        starred.isAcceptableOrUnknown(data['starred']!, _starredMeta),
      );
    }
    if (data.containsKey('user_label')) {
      context.handle(
        _userLabelMeta,
        userLabel.isAcceptableOrUnknown(data['user_label']!, _userLabelMeta),
      );
    }
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Event map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Event(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      startedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}started_at'],
      )!,
      endedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}ended_at'],
      )!,
      durationMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}duration_ms'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      schemaVersion: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}schema_version'],
      )!,
      state: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}state'],
      )!,
      topLabel: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}top_label'],
      ),
      labelsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}labels_json'],
      ),
      audioPath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}audio_path'],
      )!,
      peaksPath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}peaks_path'],
      ),
      starred: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}starred'],
      )!,
      userLabel: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}user_label'],
      ),
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}deleted_at'],
      ),
    );
  }

  @override
  $EventsTable createAlias(String alias) {
    return $EventsTable(attachedDatabase, alias);
  }
}

class Event extends DataClass implements Insertable<Event> {
  final int id;

  /// Wall-clock epoch ms when the gate opened (event start). Used to
  /// place the event on the night timeline; indexed.
  final int startedAt;

  /// Wall-clock epoch ms when the gate closed (event end).
  final int endedAt;

  /// `endedAt - startedAt`, denormalised so the timeline doesn't compute
  /// it per render.
  final int durationMs;

  /// Audit field — when the row was inserted. Drives the pending-sweep
  /// 60-second grace window (`createdAt < now - 60s` and still pending →
  /// the encoder crashed mid-flight).
  final int createdAt;

  /// Always 1 in v1. The `MigrationStrategy` in `db.dart` will bump this
  /// column when the schema changes; existing rows will be migrated by
  /// the `onUpgrade` hook.
  final int schemaVersion;

  /// `'pending'` immediately after insert; `'ready'` once the encoder
  /// has finished writing the file and `EventRepo.markReady` has run.
  /// The pending sweep targets stale `'pending'` rows; the timeline
  /// query filters to `'ready'`.
  final String state;

  /// Curated top label (e.g. `'Snoring'`, `'Other'`) — pre-computed from
  /// `labelsJson` at the moment of `markReady`. Null while the row is
  /// pending. See file-header note on why this column exists.
  final String? topLabel;

  /// JSON-encoded `Map<String, double>` of curated label → confidence.
  /// Source of truth for the relabel UI; the displayed label uses
  /// `topLabel` first to avoid re-parsing on every render.
  final String? labelsJson;

  /// Path to the encoded `.opus` file, **relative to**
  /// `getApplicationDocumentsDirectory()`. Canonical layout is
  /// `events/YYYY-MM-DD/<startedAt>.opus`. The DB does NOT store
  /// absolute paths (see file-header note on iOS sandbox UUIDs).
  final String audioPath;

  /// Path to the pre-computed waveform peaks sidecar, also relative.
  /// Null until `markReady` (Phase 7 writes the peaks file alongside
  /// the encoded audio).
  final String? peaksPath;

  /// User-facing star toggle. Starred events are exempt from auto-prune
  /// and from quota-under-pressure soft-deletion (Phase 9).
  final bool starred;

  /// User-supplied label override. When set, the UI displays this
  /// instead of `topLabel`. Null clears the override.
  final String? userLabel;

  /// Soft-delete tombstone. Non-null = the row is hidden from the
  /// timeline. The Phase 9 hard-delete pass eventually removes rows
  /// where `deletedAt < now - hardDeleteAfterDays`.
  final int? deletedAt;
  const Event({
    required this.id,
    required this.startedAt,
    required this.endedAt,
    required this.durationMs,
    required this.createdAt,
    required this.schemaVersion,
    required this.state,
    this.topLabel,
    this.labelsJson,
    required this.audioPath,
    this.peaksPath,
    required this.starred,
    this.userLabel,
    this.deletedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['started_at'] = Variable<int>(startedAt);
    map['ended_at'] = Variable<int>(endedAt);
    map['duration_ms'] = Variable<int>(durationMs);
    map['created_at'] = Variable<int>(createdAt);
    map['schema_version'] = Variable<int>(schemaVersion);
    map['state'] = Variable<String>(state);
    if (!nullToAbsent || topLabel != null) {
      map['top_label'] = Variable<String>(topLabel);
    }
    if (!nullToAbsent || labelsJson != null) {
      map['labels_json'] = Variable<String>(labelsJson);
    }
    map['audio_path'] = Variable<String>(audioPath);
    if (!nullToAbsent || peaksPath != null) {
      map['peaks_path'] = Variable<String>(peaksPath);
    }
    map['starred'] = Variable<bool>(starred);
    if (!nullToAbsent || userLabel != null) {
      map['user_label'] = Variable<String>(userLabel);
    }
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<int>(deletedAt);
    }
    return map;
  }

  EventsCompanion toCompanion(bool nullToAbsent) {
    return EventsCompanion(
      id: Value(id),
      startedAt: Value(startedAt),
      endedAt: Value(endedAt),
      durationMs: Value(durationMs),
      createdAt: Value(createdAt),
      schemaVersion: Value(schemaVersion),
      state: Value(state),
      topLabel: topLabel == null && nullToAbsent
          ? const Value.absent()
          : Value(topLabel),
      labelsJson: labelsJson == null && nullToAbsent
          ? const Value.absent()
          : Value(labelsJson),
      audioPath: Value(audioPath),
      peaksPath: peaksPath == null && nullToAbsent
          ? const Value.absent()
          : Value(peaksPath),
      starred: Value(starred),
      userLabel: userLabel == null && nullToAbsent
          ? const Value.absent()
          : Value(userLabel),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
    );
  }

  factory Event.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Event(
      id: serializer.fromJson<int>(json['id']),
      startedAt: serializer.fromJson<int>(json['startedAt']),
      endedAt: serializer.fromJson<int>(json['endedAt']),
      durationMs: serializer.fromJson<int>(json['durationMs']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      schemaVersion: serializer.fromJson<int>(json['schemaVersion']),
      state: serializer.fromJson<String>(json['state']),
      topLabel: serializer.fromJson<String?>(json['topLabel']),
      labelsJson: serializer.fromJson<String?>(json['labelsJson']),
      audioPath: serializer.fromJson<String>(json['audioPath']),
      peaksPath: serializer.fromJson<String?>(json['peaksPath']),
      starred: serializer.fromJson<bool>(json['starred']),
      userLabel: serializer.fromJson<String?>(json['userLabel']),
      deletedAt: serializer.fromJson<int?>(json['deletedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'startedAt': serializer.toJson<int>(startedAt),
      'endedAt': serializer.toJson<int>(endedAt),
      'durationMs': serializer.toJson<int>(durationMs),
      'createdAt': serializer.toJson<int>(createdAt),
      'schemaVersion': serializer.toJson<int>(schemaVersion),
      'state': serializer.toJson<String>(state),
      'topLabel': serializer.toJson<String?>(topLabel),
      'labelsJson': serializer.toJson<String?>(labelsJson),
      'audioPath': serializer.toJson<String>(audioPath),
      'peaksPath': serializer.toJson<String?>(peaksPath),
      'starred': serializer.toJson<bool>(starred),
      'userLabel': serializer.toJson<String?>(userLabel),
      'deletedAt': serializer.toJson<int?>(deletedAt),
    };
  }

  Event copyWith({
    int? id,
    int? startedAt,
    int? endedAt,
    int? durationMs,
    int? createdAt,
    int? schemaVersion,
    String? state,
    Value<String?> topLabel = const Value.absent(),
    Value<String?> labelsJson = const Value.absent(),
    String? audioPath,
    Value<String?> peaksPath = const Value.absent(),
    bool? starred,
    Value<String?> userLabel = const Value.absent(),
    Value<int?> deletedAt = const Value.absent(),
  }) => Event(
    id: id ?? this.id,
    startedAt: startedAt ?? this.startedAt,
    endedAt: endedAt ?? this.endedAt,
    durationMs: durationMs ?? this.durationMs,
    createdAt: createdAt ?? this.createdAt,
    schemaVersion: schemaVersion ?? this.schemaVersion,
    state: state ?? this.state,
    topLabel: topLabel.present ? topLabel.value : this.topLabel,
    labelsJson: labelsJson.present ? labelsJson.value : this.labelsJson,
    audioPath: audioPath ?? this.audioPath,
    peaksPath: peaksPath.present ? peaksPath.value : this.peaksPath,
    starred: starred ?? this.starred,
    userLabel: userLabel.present ? userLabel.value : this.userLabel,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
  );
  Event copyWithCompanion(EventsCompanion data) {
    return Event(
      id: data.id.present ? data.id.value : this.id,
      startedAt: data.startedAt.present ? data.startedAt.value : this.startedAt,
      endedAt: data.endedAt.present ? data.endedAt.value : this.endedAt,
      durationMs: data.durationMs.present
          ? data.durationMs.value
          : this.durationMs,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      schemaVersion: data.schemaVersion.present
          ? data.schemaVersion.value
          : this.schemaVersion,
      state: data.state.present ? data.state.value : this.state,
      topLabel: data.topLabel.present ? data.topLabel.value : this.topLabel,
      labelsJson: data.labelsJson.present
          ? data.labelsJson.value
          : this.labelsJson,
      audioPath: data.audioPath.present ? data.audioPath.value : this.audioPath,
      peaksPath: data.peaksPath.present ? data.peaksPath.value : this.peaksPath,
      starred: data.starred.present ? data.starred.value : this.starred,
      userLabel: data.userLabel.present ? data.userLabel.value : this.userLabel,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Event(')
          ..write('id: $id, ')
          ..write('startedAt: $startedAt, ')
          ..write('endedAt: $endedAt, ')
          ..write('durationMs: $durationMs, ')
          ..write('createdAt: $createdAt, ')
          ..write('schemaVersion: $schemaVersion, ')
          ..write('state: $state, ')
          ..write('topLabel: $topLabel, ')
          ..write('labelsJson: $labelsJson, ')
          ..write('audioPath: $audioPath, ')
          ..write('peaksPath: $peaksPath, ')
          ..write('starred: $starred, ')
          ..write('userLabel: $userLabel, ')
          ..write('deletedAt: $deletedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    startedAt,
    endedAt,
    durationMs,
    createdAt,
    schemaVersion,
    state,
    topLabel,
    labelsJson,
    audioPath,
    peaksPath,
    starred,
    userLabel,
    deletedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Event &&
          other.id == this.id &&
          other.startedAt == this.startedAt &&
          other.endedAt == this.endedAt &&
          other.durationMs == this.durationMs &&
          other.createdAt == this.createdAt &&
          other.schemaVersion == this.schemaVersion &&
          other.state == this.state &&
          other.topLabel == this.topLabel &&
          other.labelsJson == this.labelsJson &&
          other.audioPath == this.audioPath &&
          other.peaksPath == this.peaksPath &&
          other.starred == this.starred &&
          other.userLabel == this.userLabel &&
          other.deletedAt == this.deletedAt);
}

class EventsCompanion extends UpdateCompanion<Event> {
  final Value<int> id;
  final Value<int> startedAt;
  final Value<int> endedAt;
  final Value<int> durationMs;
  final Value<int> createdAt;
  final Value<int> schemaVersion;
  final Value<String> state;
  final Value<String?> topLabel;
  final Value<String?> labelsJson;
  final Value<String> audioPath;
  final Value<String?> peaksPath;
  final Value<bool> starred;
  final Value<String?> userLabel;
  final Value<int?> deletedAt;
  const EventsCompanion({
    this.id = const Value.absent(),
    this.startedAt = const Value.absent(),
    this.endedAt = const Value.absent(),
    this.durationMs = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.schemaVersion = const Value.absent(),
    this.state = const Value.absent(),
    this.topLabel = const Value.absent(),
    this.labelsJson = const Value.absent(),
    this.audioPath = const Value.absent(),
    this.peaksPath = const Value.absent(),
    this.starred = const Value.absent(),
    this.userLabel = const Value.absent(),
    this.deletedAt = const Value.absent(),
  });
  EventsCompanion.insert({
    this.id = const Value.absent(),
    required int startedAt,
    required int endedAt,
    required int durationMs,
    required int createdAt,
    this.schemaVersion = const Value.absent(),
    this.state = const Value.absent(),
    this.topLabel = const Value.absent(),
    this.labelsJson = const Value.absent(),
    required String audioPath,
    this.peaksPath = const Value.absent(),
    this.starred = const Value.absent(),
    this.userLabel = const Value.absent(),
    this.deletedAt = const Value.absent(),
  }) : startedAt = Value(startedAt),
       endedAt = Value(endedAt),
       durationMs = Value(durationMs),
       createdAt = Value(createdAt),
       audioPath = Value(audioPath);
  static Insertable<Event> custom({
    Expression<int>? id,
    Expression<int>? startedAt,
    Expression<int>? endedAt,
    Expression<int>? durationMs,
    Expression<int>? createdAt,
    Expression<int>? schemaVersion,
    Expression<String>? state,
    Expression<String>? topLabel,
    Expression<String>? labelsJson,
    Expression<String>? audioPath,
    Expression<String>? peaksPath,
    Expression<bool>? starred,
    Expression<String>? userLabel,
    Expression<int>? deletedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (startedAt != null) 'started_at': startedAt,
      if (endedAt != null) 'ended_at': endedAt,
      if (durationMs != null) 'duration_ms': durationMs,
      if (createdAt != null) 'created_at': createdAt,
      if (schemaVersion != null) 'schema_version': schemaVersion,
      if (state != null) 'state': state,
      if (topLabel != null) 'top_label': topLabel,
      if (labelsJson != null) 'labels_json': labelsJson,
      if (audioPath != null) 'audio_path': audioPath,
      if (peaksPath != null) 'peaks_path': peaksPath,
      if (starred != null) 'starred': starred,
      if (userLabel != null) 'user_label': userLabel,
      if (deletedAt != null) 'deleted_at': deletedAt,
    });
  }

  EventsCompanion copyWith({
    Value<int>? id,
    Value<int>? startedAt,
    Value<int>? endedAt,
    Value<int>? durationMs,
    Value<int>? createdAt,
    Value<int>? schemaVersion,
    Value<String>? state,
    Value<String?>? topLabel,
    Value<String?>? labelsJson,
    Value<String>? audioPath,
    Value<String?>? peaksPath,
    Value<bool>? starred,
    Value<String?>? userLabel,
    Value<int?>? deletedAt,
  }) {
    return EventsCompanion(
      id: id ?? this.id,
      startedAt: startedAt ?? this.startedAt,
      endedAt: endedAt ?? this.endedAt,
      durationMs: durationMs ?? this.durationMs,
      createdAt: createdAt ?? this.createdAt,
      schemaVersion: schemaVersion ?? this.schemaVersion,
      state: state ?? this.state,
      topLabel: topLabel ?? this.topLabel,
      labelsJson: labelsJson ?? this.labelsJson,
      audioPath: audioPath ?? this.audioPath,
      peaksPath: peaksPath ?? this.peaksPath,
      starred: starred ?? this.starred,
      userLabel: userLabel ?? this.userLabel,
      deletedAt: deletedAt ?? this.deletedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (startedAt.present) {
      map['started_at'] = Variable<int>(startedAt.value);
    }
    if (endedAt.present) {
      map['ended_at'] = Variable<int>(endedAt.value);
    }
    if (durationMs.present) {
      map['duration_ms'] = Variable<int>(durationMs.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (schemaVersion.present) {
      map['schema_version'] = Variable<int>(schemaVersion.value);
    }
    if (state.present) {
      map['state'] = Variable<String>(state.value);
    }
    if (topLabel.present) {
      map['top_label'] = Variable<String>(topLabel.value);
    }
    if (labelsJson.present) {
      map['labels_json'] = Variable<String>(labelsJson.value);
    }
    if (audioPath.present) {
      map['audio_path'] = Variable<String>(audioPath.value);
    }
    if (peaksPath.present) {
      map['peaks_path'] = Variable<String>(peaksPath.value);
    }
    if (starred.present) {
      map['starred'] = Variable<bool>(starred.value);
    }
    if (userLabel.present) {
      map['user_label'] = Variable<String>(userLabel.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<int>(deletedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('EventsCompanion(')
          ..write('id: $id, ')
          ..write('startedAt: $startedAt, ')
          ..write('endedAt: $endedAt, ')
          ..write('durationMs: $durationMs, ')
          ..write('createdAt: $createdAt, ')
          ..write('schemaVersion: $schemaVersion, ')
          ..write('state: $state, ')
          ..write('topLabel: $topLabel, ')
          ..write('labelsJson: $labelsJson, ')
          ..write('audioPath: $audioPath, ')
          ..write('peaksPath: $peaksPath, ')
          ..write('starred: $starred, ')
          ..write('userLabel: $userLabel, ')
          ..write('deletedAt: $deletedAt')
          ..write(')'))
        .toString();
  }
}

class $RecordingGapsTable extends RecordingGaps
    with TableInfo<$RecordingGapsTable, RecordingGap> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $RecordingGapsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _startedAtMeta = const VerificationMeta(
    'startedAt',
  );
  @override
  late final GeneratedColumn<int> startedAt = GeneratedColumn<int>(
    'started_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _endedAtMeta = const VerificationMeta(
    'endedAt',
  );
  @override
  late final GeneratedColumn<int> endedAt = GeneratedColumn<int>(
    'ended_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _reasonMeta = const VerificationMeta('reason');
  @override
  late final GeneratedColumn<String> reason = GeneratedColumn<String>(
    'reason',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [id, startedAt, endedAt, reason];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'recording_gaps';
  @override
  VerificationContext validateIntegrity(
    Insertable<RecordingGap> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('started_at')) {
      context.handle(
        _startedAtMeta,
        startedAt.isAcceptableOrUnknown(data['started_at']!, _startedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_startedAtMeta);
    }
    if (data.containsKey('ended_at')) {
      context.handle(
        _endedAtMeta,
        endedAt.isAcceptableOrUnknown(data['ended_at']!, _endedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_endedAtMeta);
    }
    if (data.containsKey('reason')) {
      context.handle(
        _reasonMeta,
        reason.isAcceptableOrUnknown(data['reason']!, _reasonMeta),
      );
    } else if (isInserting) {
      context.missing(_reasonMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  RecordingGap map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return RecordingGap(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      startedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}started_at'],
      )!,
      endedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}ended_at'],
      )!,
      reason: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}reason'],
      )!,
    );
  }

  @override
  $RecordingGapsTable createAlias(String alias) {
    return $RecordingGapsTable(attachedDatabase, alias);
  }
}

class RecordingGap extends DataClass implements Insertable<RecordingGap> {
  final int id;

  /// Epoch ms when the recorder went deaf.
  final int startedAt;

  /// Epoch ms when the recorder resumed (or was given up on, in the
  /// crash case where the gap end is the last heartbeat timestamp).
  final int endedAt;

  /// One of `'interruption'`, `'route_change'`, `'crash'`. See
  /// file-header.
  final String reason;
  const RecordingGap({
    required this.id,
    required this.startedAt,
    required this.endedAt,
    required this.reason,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['started_at'] = Variable<int>(startedAt);
    map['ended_at'] = Variable<int>(endedAt);
    map['reason'] = Variable<String>(reason);
    return map;
  }

  RecordingGapsCompanion toCompanion(bool nullToAbsent) {
    return RecordingGapsCompanion(
      id: Value(id),
      startedAt: Value(startedAt),
      endedAt: Value(endedAt),
      reason: Value(reason),
    );
  }

  factory RecordingGap.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return RecordingGap(
      id: serializer.fromJson<int>(json['id']),
      startedAt: serializer.fromJson<int>(json['startedAt']),
      endedAt: serializer.fromJson<int>(json['endedAt']),
      reason: serializer.fromJson<String>(json['reason']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'startedAt': serializer.toJson<int>(startedAt),
      'endedAt': serializer.toJson<int>(endedAt),
      'reason': serializer.toJson<String>(reason),
    };
  }

  RecordingGap copyWith({
    int? id,
    int? startedAt,
    int? endedAt,
    String? reason,
  }) => RecordingGap(
    id: id ?? this.id,
    startedAt: startedAt ?? this.startedAt,
    endedAt: endedAt ?? this.endedAt,
    reason: reason ?? this.reason,
  );
  RecordingGap copyWithCompanion(RecordingGapsCompanion data) {
    return RecordingGap(
      id: data.id.present ? data.id.value : this.id,
      startedAt: data.startedAt.present ? data.startedAt.value : this.startedAt,
      endedAt: data.endedAt.present ? data.endedAt.value : this.endedAt,
      reason: data.reason.present ? data.reason.value : this.reason,
    );
  }

  @override
  String toString() {
    return (StringBuffer('RecordingGap(')
          ..write('id: $id, ')
          ..write('startedAt: $startedAt, ')
          ..write('endedAt: $endedAt, ')
          ..write('reason: $reason')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, startedAt, endedAt, reason);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RecordingGap &&
          other.id == this.id &&
          other.startedAt == this.startedAt &&
          other.endedAt == this.endedAt &&
          other.reason == this.reason);
}

class RecordingGapsCompanion extends UpdateCompanion<RecordingGap> {
  final Value<int> id;
  final Value<int> startedAt;
  final Value<int> endedAt;
  final Value<String> reason;
  const RecordingGapsCompanion({
    this.id = const Value.absent(),
    this.startedAt = const Value.absent(),
    this.endedAt = const Value.absent(),
    this.reason = const Value.absent(),
  });
  RecordingGapsCompanion.insert({
    this.id = const Value.absent(),
    required int startedAt,
    required int endedAt,
    required String reason,
  }) : startedAt = Value(startedAt),
       endedAt = Value(endedAt),
       reason = Value(reason);
  static Insertable<RecordingGap> custom({
    Expression<int>? id,
    Expression<int>? startedAt,
    Expression<int>? endedAt,
    Expression<String>? reason,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (startedAt != null) 'started_at': startedAt,
      if (endedAt != null) 'ended_at': endedAt,
      if (reason != null) 'reason': reason,
    });
  }

  RecordingGapsCompanion copyWith({
    Value<int>? id,
    Value<int>? startedAt,
    Value<int>? endedAt,
    Value<String>? reason,
  }) {
    return RecordingGapsCompanion(
      id: id ?? this.id,
      startedAt: startedAt ?? this.startedAt,
      endedAt: endedAt ?? this.endedAt,
      reason: reason ?? this.reason,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (startedAt.present) {
      map['started_at'] = Variable<int>(startedAt.value);
    }
    if (endedAt.present) {
      map['ended_at'] = Variable<int>(endedAt.value);
    }
    if (reason.present) {
      map['reason'] = Variable<String>(reason.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('RecordingGapsCompanion(')
          ..write('id: $id, ')
          ..write('startedAt: $startedAt, ')
          ..write('endedAt: $endedAt, ')
          ..write('reason: $reason')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDb extends GeneratedDatabase {
  _$AppDb(QueryExecutor e) : super(e);
  $AppDbManager get managers => $AppDbManager(this);
  late final $EventsTable events = $EventsTable(this);
  late final $RecordingGapsTable recordingGaps = $RecordingGapsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [events, recordingGaps];
}

typedef $$EventsTableCreateCompanionBuilder =
    EventsCompanion Function({
      Value<int> id,
      required int startedAt,
      required int endedAt,
      required int durationMs,
      required int createdAt,
      Value<int> schemaVersion,
      Value<String> state,
      Value<String?> topLabel,
      Value<String?> labelsJson,
      required String audioPath,
      Value<String?> peaksPath,
      Value<bool> starred,
      Value<String?> userLabel,
      Value<int?> deletedAt,
    });
typedef $$EventsTableUpdateCompanionBuilder =
    EventsCompanion Function({
      Value<int> id,
      Value<int> startedAt,
      Value<int> endedAt,
      Value<int> durationMs,
      Value<int> createdAt,
      Value<int> schemaVersion,
      Value<String> state,
      Value<String?> topLabel,
      Value<String?> labelsJson,
      Value<String> audioPath,
      Value<String?> peaksPath,
      Value<bool> starred,
      Value<String?> userLabel,
      Value<int?> deletedAt,
    });

class $$EventsTableFilterComposer extends Composer<_$AppDb, $EventsTable> {
  $$EventsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get startedAt => $composableBuilder(
    column: $table.startedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get endedAt => $composableBuilder(
    column: $table.endedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get schemaVersion => $composableBuilder(
    column: $table.schemaVersion,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get topLabel => $composableBuilder(
    column: $table.topLabel,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get labelsJson => $composableBuilder(
    column: $table.labelsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get audioPath => $composableBuilder(
    column: $table.audioPath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get peaksPath => $composableBuilder(
    column: $table.peaksPath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get starred => $composableBuilder(
    column: $table.starred,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get userLabel => $composableBuilder(
    column: $table.userLabel,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$EventsTableOrderingComposer extends Composer<_$AppDb, $EventsTable> {
  $$EventsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get startedAt => $composableBuilder(
    column: $table.startedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get endedAt => $composableBuilder(
    column: $table.endedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get schemaVersion => $composableBuilder(
    column: $table.schemaVersion,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get topLabel => $composableBuilder(
    column: $table.topLabel,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get labelsJson => $composableBuilder(
    column: $table.labelsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get audioPath => $composableBuilder(
    column: $table.audioPath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get peaksPath => $composableBuilder(
    column: $table.peaksPath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get starred => $composableBuilder(
    column: $table.starred,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get userLabel => $composableBuilder(
    column: $table.userLabel,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$EventsTableAnnotationComposer extends Composer<_$AppDb, $EventsTable> {
  $$EventsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get startedAt =>
      $composableBuilder(column: $table.startedAt, builder: (column) => column);

  GeneratedColumn<int> get endedAt =>
      $composableBuilder(column: $table.endedAt, builder: (column) => column);

  GeneratedColumn<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get schemaVersion => $composableBuilder(
    column: $table.schemaVersion,
    builder: (column) => column,
  );

  GeneratedColumn<String> get state =>
      $composableBuilder(column: $table.state, builder: (column) => column);

  GeneratedColumn<String> get topLabel =>
      $composableBuilder(column: $table.topLabel, builder: (column) => column);

  GeneratedColumn<String> get labelsJson => $composableBuilder(
    column: $table.labelsJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get audioPath =>
      $composableBuilder(column: $table.audioPath, builder: (column) => column);

  GeneratedColumn<String> get peaksPath =>
      $composableBuilder(column: $table.peaksPath, builder: (column) => column);

  GeneratedColumn<bool> get starred =>
      $composableBuilder(column: $table.starred, builder: (column) => column);

  GeneratedColumn<String> get userLabel =>
      $composableBuilder(column: $table.userLabel, builder: (column) => column);

  GeneratedColumn<int> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);
}

class $$EventsTableTableManager
    extends
        RootTableManager<
          _$AppDb,
          $EventsTable,
          Event,
          $$EventsTableFilterComposer,
          $$EventsTableOrderingComposer,
          $$EventsTableAnnotationComposer,
          $$EventsTableCreateCompanionBuilder,
          $$EventsTableUpdateCompanionBuilder,
          (Event, BaseReferences<_$AppDb, $EventsTable, Event>),
          Event,
          PrefetchHooks Function()
        > {
  $$EventsTableTableManager(_$AppDb db, $EventsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$EventsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$EventsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$EventsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> startedAt = const Value.absent(),
                Value<int> endedAt = const Value.absent(),
                Value<int> durationMs = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> schemaVersion = const Value.absent(),
                Value<String> state = const Value.absent(),
                Value<String?> topLabel = const Value.absent(),
                Value<String?> labelsJson = const Value.absent(),
                Value<String> audioPath = const Value.absent(),
                Value<String?> peaksPath = const Value.absent(),
                Value<bool> starred = const Value.absent(),
                Value<String?> userLabel = const Value.absent(),
                Value<int?> deletedAt = const Value.absent(),
              }) => EventsCompanion(
                id: id,
                startedAt: startedAt,
                endedAt: endedAt,
                durationMs: durationMs,
                createdAt: createdAt,
                schemaVersion: schemaVersion,
                state: state,
                topLabel: topLabel,
                labelsJson: labelsJson,
                audioPath: audioPath,
                peaksPath: peaksPath,
                starred: starred,
                userLabel: userLabel,
                deletedAt: deletedAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int startedAt,
                required int endedAt,
                required int durationMs,
                required int createdAt,
                Value<int> schemaVersion = const Value.absent(),
                Value<String> state = const Value.absent(),
                Value<String?> topLabel = const Value.absent(),
                Value<String?> labelsJson = const Value.absent(),
                required String audioPath,
                Value<String?> peaksPath = const Value.absent(),
                Value<bool> starred = const Value.absent(),
                Value<String?> userLabel = const Value.absent(),
                Value<int?> deletedAt = const Value.absent(),
              }) => EventsCompanion.insert(
                id: id,
                startedAt: startedAt,
                endedAt: endedAt,
                durationMs: durationMs,
                createdAt: createdAt,
                schemaVersion: schemaVersion,
                state: state,
                topLabel: topLabel,
                labelsJson: labelsJson,
                audioPath: audioPath,
                peaksPath: peaksPath,
                starred: starred,
                userLabel: userLabel,
                deletedAt: deletedAt,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$EventsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDb,
      $EventsTable,
      Event,
      $$EventsTableFilterComposer,
      $$EventsTableOrderingComposer,
      $$EventsTableAnnotationComposer,
      $$EventsTableCreateCompanionBuilder,
      $$EventsTableUpdateCompanionBuilder,
      (Event, BaseReferences<_$AppDb, $EventsTable, Event>),
      Event,
      PrefetchHooks Function()
    >;
typedef $$RecordingGapsTableCreateCompanionBuilder =
    RecordingGapsCompanion Function({
      Value<int> id,
      required int startedAt,
      required int endedAt,
      required String reason,
    });
typedef $$RecordingGapsTableUpdateCompanionBuilder =
    RecordingGapsCompanion Function({
      Value<int> id,
      Value<int> startedAt,
      Value<int> endedAt,
      Value<String> reason,
    });

class $$RecordingGapsTableFilterComposer
    extends Composer<_$AppDb, $RecordingGapsTable> {
  $$RecordingGapsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get startedAt => $composableBuilder(
    column: $table.startedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get endedAt => $composableBuilder(
    column: $table.endedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get reason => $composableBuilder(
    column: $table.reason,
    builder: (column) => ColumnFilters(column),
  );
}

class $$RecordingGapsTableOrderingComposer
    extends Composer<_$AppDb, $RecordingGapsTable> {
  $$RecordingGapsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get startedAt => $composableBuilder(
    column: $table.startedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get endedAt => $composableBuilder(
    column: $table.endedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get reason => $composableBuilder(
    column: $table.reason,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$RecordingGapsTableAnnotationComposer
    extends Composer<_$AppDb, $RecordingGapsTable> {
  $$RecordingGapsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get startedAt =>
      $composableBuilder(column: $table.startedAt, builder: (column) => column);

  GeneratedColumn<int> get endedAt =>
      $composableBuilder(column: $table.endedAt, builder: (column) => column);

  GeneratedColumn<String> get reason =>
      $composableBuilder(column: $table.reason, builder: (column) => column);
}

class $$RecordingGapsTableTableManager
    extends
        RootTableManager<
          _$AppDb,
          $RecordingGapsTable,
          RecordingGap,
          $$RecordingGapsTableFilterComposer,
          $$RecordingGapsTableOrderingComposer,
          $$RecordingGapsTableAnnotationComposer,
          $$RecordingGapsTableCreateCompanionBuilder,
          $$RecordingGapsTableUpdateCompanionBuilder,
          (
            RecordingGap,
            BaseReferences<_$AppDb, $RecordingGapsTable, RecordingGap>,
          ),
          RecordingGap,
          PrefetchHooks Function()
        > {
  $$RecordingGapsTableTableManager(_$AppDb db, $RecordingGapsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$RecordingGapsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$RecordingGapsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$RecordingGapsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> startedAt = const Value.absent(),
                Value<int> endedAt = const Value.absent(),
                Value<String> reason = const Value.absent(),
              }) => RecordingGapsCompanion(
                id: id,
                startedAt: startedAt,
                endedAt: endedAt,
                reason: reason,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int startedAt,
                required int endedAt,
                required String reason,
              }) => RecordingGapsCompanion.insert(
                id: id,
                startedAt: startedAt,
                endedAt: endedAt,
                reason: reason,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$RecordingGapsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDb,
      $RecordingGapsTable,
      RecordingGap,
      $$RecordingGapsTableFilterComposer,
      $$RecordingGapsTableOrderingComposer,
      $$RecordingGapsTableAnnotationComposer,
      $$RecordingGapsTableCreateCompanionBuilder,
      $$RecordingGapsTableUpdateCompanionBuilder,
      (
        RecordingGap,
        BaseReferences<_$AppDb, $RecordingGapsTable, RecordingGap>,
      ),
      RecordingGap,
      PrefetchHooks Function()
    >;

class $AppDbManager {
  final _$AppDb _db;
  $AppDbManager(this._db);
  $$EventsTableTableManager get events =>
      $$EventsTableTableManager(_db, _db.events);
  $$RecordingGapsTableTableManager get recordingGaps =>
      $$RecordingGapsTableTableManager(_db, _db.recordingGaps);
}
