import 'dart:math';

enum Suit {
  bastos,
  copas,
  oros,
  espadas;

  String get label {
    switch (this) {
      case Suit.bastos:
        return 'Bastos';
      case Suit.copas:
        return 'Copas';
      case Suit.oros:
        return 'Oros';
      case Suit.espadas:
        return 'Espadas';
    }
  }

  static Suit fromLabel(String label) {
    return Suit.values.firstWhere((suit) => suit.label == label);
  }
}

class SpanishCard {
  final int value;
  final Suit suit;

  const SpanishCard({required this.value, required this.suit});

  String get rankLabel {
    switch (value) {
      case 1:
        return 'As';
      case 10:
        return 'Sota';
      case 11:
        return 'Caballo';
      case 12:
        return 'Rey';
      default:
        return value.toString();
    }
  }

  @override
  String toString() => '$rankLabel de ${suit.label}';

  @override
  bool operator ==(Object other) {
    return other is SpanishCard && other.value == value && other.suit == suit;
  }

  @override
  int get hashCode => Object.hash(value, suit);

  Map<String, dynamic> toJson() => {'value': value, 'suit': suit.label};

  factory SpanishCard.fromJson(Map<String, dynamic> json) {
    return SpanishCard(
      value: json['value'] as int,
      suit: Suit.fromLabel(json['suit'] as String),
    );
  }
}

class ZapitiDeck {
  const ZapitiDeck._();

  static List<SpanishCard> fullDeck() {
    const values = [1, 2, 3, 4, 5, 6, 7, 10, 11, 12];
    return [
      for (final suit in Suit.values)
        for (final value in values) SpanishCard(value: value, suit: suit),
    ];
  }

  static List<SpanishCard> shuffled({Random? random}) {
    final deck = fullDeck();
    deck.shuffle(random);
    return deck;
  }
}

class ZapitiRules {
  const ZapitiRules._();

  static int strength(SpanishCard card) {
    if (card.value == 4 && card.suit == Suit.bastos) return 100;
    if (card.value == 7 && card.suit == Suit.copas) return 99;
    if (card.value == 7 && card.suit == Suit.oros) return 98;
    if (card.value == 1 && card.suit == Suit.espadas) return 97;

    if (card.value == 3) return 90;
    if (card.value == 2) return 80;
    if (card.value == 1) return 70;

    if (card.value == 12) return 60;
    if (card.value == 11) return 50;
    if (card.value == 10) return 40;

    if (card.value == 7) return 30;
    if (card.value == 6) return 20;
    if (card.value == 5) return 10;
    if (card.value == 4) return 5;

    return 0;
  }
}

class MatchPlayer {
  final String playerId;
  final String name;
  final int teamId;
  final String? connectionId;
  final String? pairId;
  final String? teamName;
  final String characterId;
  final int aiDifficulty;

  const MatchPlayer({
    required this.playerId,
    required this.name,
    required this.teamId,
    this.connectionId,
    this.pairId,
    this.teamName,
    required this.characterId,
    this.aiDifficulty = 3,
  });

  bool get isBot => connectionId == null;

  Map<String, dynamic> toJson() => {
    'playerId': playerId,
    'name': name,
    'teamId': teamId,
    if (pairId != null) 'pairId': pairId,
    if (teamName != null) 'teamName': teamName,
    'characterId': characterId,
    if (isBot) 'aiDifficulty': aiDifficulty,
  };
}

enum BotTrucoAction { accept, pass, raise }

class BotTrucoDecision {
  final BotTrucoAction action;
  final MatchPlayer player;
  final int? value;

  const BotTrucoDecision({
    required this.action,
    required this.player,
    this.value,
  });
}

class PlayedCard {
  final MatchPlayer player;
  final SpanishCard card;

  const PlayedCard({required this.player, required this.card});
}

class RoundResult {
  final PlayedCard? winner;
  final List<PlayedCard> playedCards;

  const RoundResult({required this.winner, required this.playedCards});

  bool get isTie => winner == null;
  int? get winningTeamId => winner?.player.teamId;
}

class HandProgress {
  final Map<int, int> roundWinsByTeam;
  final int? winningTeamId;
  final bool isFinished;
  final bool isNoPoints;

  const HandProgress({
    required this.roundWinsByTeam,
    required this.winningTeamId,
    required this.isFinished,
    required this.isNoPoints,
  });

  int roundWinsFor(int teamId) => roundWinsByTeam[teamId] ?? 0;
}

class RoundRules {
  const RoundRules._();

  static RoundResult resolveRound(List<PlayedCard> playedCards) {
    if (playedCards.isEmpty) {
      throw ArgumentError('No cards played.');
    }

    final bestStrength = playedCards
        .map((playedCard) => ZapitiRules.strength(playedCard.card))
        .reduce((best, current) => current > best ? current : best);

    final strongestCards = playedCards.where((playedCard) {
      return ZapitiRules.strength(playedCard.card) == bestStrength;
    }).toList();

    final strongestTeams = {
      for (final playedCard in strongestCards) playedCard.player.teamId,
    };

    final PlayedCard? winner = strongestTeams.length == 1
        ? strongestCards.first
        : null;
    return RoundResult(
      winner: winner,
      playedCards: List.unmodifiable(playedCards),
    );
  }
}

class HandRules {
  const HandRules._();

  static HandProgress resolve(List<RoundResult> rounds) {
    final roundWins = {1: 0, 2: 0};
    int? winningTeamId;
    var isFinished = false;
    var isNoPoints = false;

    for (var i = 0; i < rounds.length; i++) {
      final round = rounds[i];
      if (round.isTie) {
        _applyTiedRound(roundWins, rounds, i);
      } else {
        final teamId = round.winningTeamId!;
        roundWins[teamId] = roundWins[teamId]! + 1;
      }

      winningTeamId = _winnerFrom(roundWins);
      if (winningTeamId != null) {
        isFinished = true;
        break;
      }
    }

    if (!isFinished && rounds.length == 3 && roundWins[1] == roundWins[2]) {
      isFinished = true;
      isNoPoints = true;
    }

    return HandProgress(
      roundWinsByTeam: Map.unmodifiable(roundWins),
      winningTeamId: winningTeamId,
      isFinished: isFinished,
      isNoPoints: isNoPoints,
    );
  }

  static void _applyTiedRound(
    Map<int, int> roundWins,
    List<RoundResult> rounds,
    int roundIndex,
  ) {
    if (roundIndex == 0) {
      roundWins[1] = roundWins[1]! + 1;
      roundWins[2] = roundWins[2]! + 1;
      return;
    }

    if (roundIndex == 1) {
      final firstRoundWinner = rounds.first.winningTeamId;
      if (firstRoundWinner != null) {
        roundWins[firstRoundWinner] = roundWins[firstRoundWinner]! + 1;
      }
    }
  }

  static int? _winnerFrom(Map<int, int> roundWins) {
    if (roundWins[1] == 2) return 1;
    if (roundWins[2] == 2) return 2;
    return null;
  }
}

class TrucoRules {
  const TrucoRules._();

  static const int firstTrucoValue = 3;
  static const int raiseStep = 3;

  static int maxAllowedValue({
    required int scoreTeamOne,
    required int scoreTeamTwo,
    required int targetScore,
    required int currentAcceptedValue,
  }) {
    final maxForTeamOne = targetScore - 1 - scoreTeamOne;
    final maxForTeamTwo = targetScore - 1 - scoreTeamTwo;
    final maxValue = maxForTeamOne < maxForTeamTwo
        ? maxForTeamOne
        : maxForTeamTwo;
    final minimumValue = currentAcceptedValue < firstTrucoValue
        ? firstTrucoValue
        : currentAcceptedValue;
    return maxValue < minimumValue ? minimumValue : maxValue;
  }

  static List<int> raiseOptions({
    required int pendingValue,
    required int maxAllowedValue,
  }) {
    final firstRaise = pendingValue + raiseStep;
    if (firstRaise > maxAllowedValue) return const [];
    return [firstRaise];
  }

  static int? nextRaiseValue({
    required int currentAcceptedValue,
    required int maxAllowedValue,
  }) {
    final options = raiseOptions(
      pendingValue: currentAcceptedValue,
      maxAllowedValue: maxAllowedValue,
    );
    return options.isEmpty ? null : options.first;
  }

  static int passPoints({required int currentAcceptedValue}) {
    return currentAcceptedValue;
  }
}

enum BetLevel {
  none(1),
  truco(3),
  six(6),
  nine(9),
  twelve(12),
  fifteen(15),
  ahorrisi(18);

  final int value;

  const BetLevel(this.value);

  static BetLevel fromAcceptedValue(int value) {
    return switch (value) {
      <= 1 => BetLevel.none,
      3 => BetLevel.truco,
      6 => BetLevel.six,
      9 => BetLevel.nine,
      12 => BetLevel.twelve,
      15 => BetLevel.fifteen,
      _ => BetLevel.ahorrisi,
    };
  }

  static BetLevel fromProposedValue(int value) {
    return switch (value) {
      3 => BetLevel.truco,
      6 => BetLevel.six,
      9 => BetLevel.nine,
      12 => BetLevel.twelve,
      15 => BetLevel.fifteen,
      _ => BetLevel.ahorrisi,
    };
  }
}

class BetStateView {
  final BetLevel acceptedLevel;
  final BetLevel? proposedLevel;
  final int? proposingTeam;
  final int? respondingTeam;
  final int? lastRaisingTeam;
  final bool responsePending;

  const BetStateView({
    required this.acceptedLevel,
    required this.proposedLevel,
    required this.proposingTeam,
    required this.respondingTeam,
    required this.lastRaisingTeam,
    required this.responsePending,
  });

  Map<String, dynamic> toJson() => {
    'acceptedLevel': acceptedLevel.name,
    if (proposedLevel != null) 'proposedLevel': proposedLevel!.name,
    if (proposingTeam != null) 'proposingTeam': proposingTeam,
    if (respondingTeam != null) 'respondingTeam': respondingTeam,
    if (lastRaisingTeam != null) 'lastRaisingTeam': lastRaisingTeam,
    'responsePending': responsePending,
  };
}

enum AlVerState { none, awaitingDecision, playing, conceded }

class PassedHandState {
  final String originalLeaderId;
  final String? passedToPlayerId;

  const PassedHandState({
    required this.originalLeaderId,
    this.passedToPlayerId,
  });

  bool get hasPassed => passedToPlayerId != null;

  PassedHandState passTo(String playerId) {
    return PassedHandState(
      originalLeaderId: originalLeaderId,
      passedToPlayerId: playerId,
    );
  }

  Map<String, dynamic> toJson() => {
    'originalLeaderId': originalLeaderId,
    if (passedToPlayerId != null) 'passedToPlayerId': passedToPlayerId,
  };
}

class MatchState {
  static const defaultTargetScore = 30;
  static const turnTimeoutSeconds = 30;

  final String roomId;
  final int createdAt;
  final int targetScore;
  final int seed;
  final List<MatchPlayer> players;
  final bool allowPassHand;
  int handSequence = 0;
  int handSeed;
  final Map<String, List<SpanishCard>> hands;
  final List<PlayedCard> playedCards = [];
  final List<RoundResult> roundHistory = [];
  final Map<int, int> score = {1: 0, 2: 0};
  final Map<int, int> roundWins = {1: 0, 2: 0};
  final Set<int> alVerTeamIds = {};

  int stateVersion = 0;
  int turnIndex = 0;
  int leadIndex = 0;
  int nextLeadIndex = 0;
  late PassedHandState passedHandState;
  int handValue = 1;
  int? pendingTrucoValue;
  int? trucoCallerTeamId;
  int? lastTrucoRaiserTeamId;
  int? winningTeamId;
  AlVerState alVerState = AlVerState.none;
  bool handFinished = false;
  bool isRoundAwaitingContinue = false;
  bool isTrucoAccepted = false;
  String phase = 'playing';
  String status = '';
  int? turnDeadlineAt;

  MatchState._({
    required this.roomId,
    required this.createdAt,
    required this.targetScore,
    required this.seed,
    required this.players,
    required this.allowPassHand,
    required this.handSeed,
    required this.hands,
  });

  factory MatchState.start({
    required String roomId,
    required int createdAt,
    required int seed,
    required List<MatchPlayer> players,
    bool allowPassHand = false,
    int targetScore = defaultTargetScore,
  }) {
    final deck = ZapitiDeck.shuffled(random: Random(seed));
    final dealtHands = {
      for (var i = 0; i < players.length; i++)
        players[i].playerId: deck.skip(i * 3).take(3).toList(),
    };

    final state = MatchState._(
      roomId: roomId,
      createdAt: createdAt,
      targetScore: targetScore,
      seed: seed,
      players: players,
      allowPassHand: allowPassHand,
      handSeed: seed,
      hands: dealtHands,
    );
    state.leadIndex = state.nextLeadIndex;
    state.nextLeadIndex = (state.nextLeadIndex + 1) % state.players.length;
    state.turnIndex = state.leadIndex;
    state._resetPassedHandState();
    state.status = state.currentPlayerId == state.humanPlayerIds.first
        ? 'Sales tu.'
        : 'Sale ${state.currentPlayer.name}.';
    state.refreshTurnDeadline();
    return state;
  }

  MatchPlayer get currentPlayer => players[turnIndex];
  String get currentPlayerId => currentPlayer.playerId;
  bool get isGameFinished => winningTeamId != null;
  List<String> get humanPlayerIds => players
      .where((player) => !player.isBot)
      .map((player) => player.playerId)
      .toList();

  int get maxAllowedTrucoValue {
    return TrucoRules.maxAllowedValue(
      scoreTeamOne: score[1]!,
      scoreTeamTwo: score[2]!,
      targetScore: targetScore,
      currentAcceptedValue: handValue,
    );
  }

  bool get isBotTurn => currentPlayer.isBot;
  bool get hasPendingTruco => pendingTrucoValue != null;
  BetStateView get betState => BetStateView(
    acceptedLevel: BetLevel.fromAcceptedValue(handValue),
    proposedLevel: pendingTrucoValue == null
        ? null
        : BetLevel.fromProposedValue(pendingTrucoValue!),
    proposingTeam: trucoCallerTeamId,
    respondingTeam: pendingTrucoValue == null ? null : trucoResponseTeamId,
    lastRaisingTeam: lastTrucoRaiserTeamId,
    responsePending: pendingTrucoValue != null,
  );
  bool get isAwaitingCardPlay =>
      !handFinished &&
      !isRoundAwaitingContinue &&
      !isGameFinished &&
      pendingTrucoValue == null &&
      alVerState != AlVerState.awaitingDecision;
  int? get alVerTeamId => alVerTeamIds.length == 1 ? alVerTeamIds.first : null;
  int get trucoResponseTeamId {
    final callerTeamId = trucoCallerTeamId;
    if (callerTeamId == null) {
      throw StateError('No truco caller.');
    }
    return callerTeamId == 1 ? 2 : 1;
  }

  int? nextTrucoValueForPlayer(String playerId) {
    if (handFinished || isGameFinished) return null;
    if (alVerState == AlVerState.awaitingDecision) return null;
    final player = playerById(playerId);
    if (alVerState != AlVerState.none && alVerTeamIds.contains(player.teamId)) {
      return null;
    }
    if (pendingTrucoValue != null) {
      if (trucoResponseTeamId != player.teamId) return null;
      return TrucoRules.nextRaiseValue(
        currentAcceptedValue: pendingTrucoValue!,
        maxAllowedValue: maxAllowedTrucoValue,
      );
    }
    if (currentPlayerId != playerId) return null;
    if (!isTrucoAccepted) {
      return TrucoRules.firstTrucoValue <= maxAllowedTrucoValue
          ? TrucoRules.firstTrucoValue
          : null;
    }
    if (lastTrucoRaiserTeamId == player.teamId) return null;
    return TrucoRules.nextRaiseValue(
      currentAcceptedValue: handValue,
      maxAllowedValue: maxAllowedTrucoValue,
    );
  }

  bool canPassHand({required String fromPlayerId, required String toPlayerId}) {
    if (!allowPassHand) return false;
    if (handFinished || isRoundAwaitingContinue || isGameFinished) return false;
    if (pendingTrucoValue != null) return false;
    if (alVerState == AlVerState.awaitingDecision) return false;
    if (roundHistory.isNotEmpty) return false;
    if (playedCards.isNotEmpty) return false;
    if (passedHandState.hasPassed) return false;
    if (fromPlayerId != currentPlayer.playerId) return false;
    if (fromPlayerId != passedHandState.originalLeaderId) return false;

    final from = playerById(fromPlayerId);
    final to = playerById(toPlayerId);
    if (from.playerId == to.playerId || from.teamId != to.teamId) return false;
    if ((hands[from.playerId] ?? const <SpanishCard>[]).isEmpty) return false;
    if ((hands[to.playerId] ?? const <SpanishCard>[]).isEmpty) return false;
    return true;
  }

  void passHand({required String fromPlayerId, required String toPlayerId}) {
    if (!canPassHand(fromPlayerId: fromPlayerId, toPlayerId: toPlayerId)) {
      throw StateError('Cannot pass hand in current state.');
    }
    final from = playerById(fromPlayerId);
    final to = playerById(toPlayerId);
    turnIndex = players.indexWhere((player) => player.playerId == to.playerId);
    passedHandState = passedHandState.passTo(to.playerId);
    status = '${from.name} pasa mano a ${to.name}. Sale ${to.name}.';
    refreshTurnDeadline();
    stateVersion += 1;
  }

  void playCard(String playerId, SpanishCard card) {
    if (handFinished || isRoundAwaitingContinue) {
      throw StateError('Cannot play in current state.');
    }
    if (playerId != currentPlayer.playerId) {
      throw StateError('Not player turn.');
    }

    final playerHand = hands[playerId];
    if (playerHand == null || !playerHand.contains(card)) {
      throw ArgumentError('Card not in hand.');
    }

    playerHand.remove(card);
    playedCards.add(PlayedCard(player: currentPlayer, card: card));

    if (playedCards.length == players.length) {
      resolveRound();
      stateVersion += 1;
      return;
    }

    turnIndex = (turnIndex + 1) % players.length;
    status = 'Turno de ${currentPlayer.name}.';
    refreshTurnDeadline();
    stateVersion += 1;
  }

  void resolveRound() {
    if (playedCards.length != players.length) {
      throw StateError('Round needs all cards.');
    }

    final roundNumber = roundHistory.length + 1;
    final result = RoundRules.resolveRound(playedCards);
    roundHistory.add(result);
    final progress = HandRules.resolve(roundHistory);
    _applyProgress(progress);

    if (result.isTie) {
      _handleTiedRound(roundNumber, progress);
    } else {
      _handleWonRound(result, progress);
    }

    isRoundAwaitingContinue = !handFinished && !isGameFinished;
    if (isRoundAwaitingContinue) {
      clearTurnDeadline();
    }
  }

  void continueRound() {
    if (!isRoundAwaitingContinue) return;
    playedCards.clear();
    isRoundAwaitingContinue = false;
    _resetPassedHandState();
    status = 'Turno de ${currentPlayer.name}.';
    refreshTurnDeadline();
    stateVersion += 1;
  }

  void callTruco(String playerId, {required int value}) {
    final player = playerById(playerId);
    if (alVerState == AlVerState.awaitingDecision) {
      throw StateError('Al ver pending.');
    }
    if (alVerState != AlVerState.none && alVerTeamIds.contains(player.teamId)) {
      throw StateError('Team al ver cannot call truco.');
    }
    final expectedValue = nextTrucoValueForPlayer(playerId);
    if (expectedValue == null || expectedValue != value) {
      throw ArgumentError('Truco call not allowed.');
    }
    pendingTrucoValue = value;
    trucoCallerTeamId = player.teamId;
    lastTrucoRaiserTeamId = player.teamId;
    isTrucoAccepted = false;
    clearTurnDeadline();
    status =
        '${player.name} sube el reparto a $value. El otro equipo debe responder.';
    stateVersion += 1;
  }

  void acceptTruco({required int teamId}) {
    final acceptedValue = pendingTrucoValue;
    if (acceptedValue == null) {
      throw StateError('No truco pending.');
    }
    if (alVerState == AlVerState.awaitingDecision) {
      throw StateError('Al ver pending.');
    }
    handValue = acceptedValue;
    pendingTrucoValue = null;
    trucoCallerTeamId = null;
    isTrucoAccepted = true;
    status = 'Equipo $teamId acepta. El reparto vale $handValue.';
    refreshTurnDeadline();
    stateVersion += 1;
  }

  void raiseTruco(String playerId, {required int value}) {
    final pending = pendingTrucoValue;
    if (pending == null) {
      throw StateError('No truco pending.');
    }
    if (alVerState == AlVerState.awaitingDecision) {
      throw StateError('Al ver pending.');
    }
    final player = playerById(playerId);
    if (alVerState != AlVerState.none && alVerTeamIds.contains(player.teamId)) {
      throw StateError('Team al ver cannot raise truco.');
    }
    handValue = pending;
    callTruco(playerId, value: value);
  }

  void passTruco({required int passingTeamId}) {
    final callerTeamId = trucoCallerTeamId;
    if (callerTeamId == null || pendingTrucoValue == null) {
      throw StateError('No truco pending.');
    }
    if (alVerState == AlVerState.awaitingDecision) {
      throw StateError('Al ver pending.');
    }
    if (passingTeamId == callerTeamId) {
      throw ArgumentError('Caller team cannot pass itself.');
    }
    final points = TrucoRules.passPoints(currentAcceptedValue: handValue);
    _finishHandForTeam(callerTeamId, points: points);
    stateVersion += 1;
  }

  void startNewHand({Map<String, List<SpanishCard>>? fixedHands}) {
    if (isGameFinished) {
      throw StateError('Game already finished.');
    }

    handSequence += 1;
    if (fixedHands == null) {
      handSeed =
          DateTime.now().microsecondsSinceEpoch ^
          Random().nextInt(1 << 32) ^
          handSequence;
    }
    hands
      ..clear()
      ..addAll(
        fixedHands == null ? _dealRandomHands() : _cloneHands(fixedHands),
      );
    playedCards.clear();
    roundHistory.clear();
    roundWins
      ..[1] = 0
      ..[2] = 0;
    handValue = 1;
    pendingTrucoValue = null;
    trucoCallerTeamId = null;
    lastTrucoRaiserTeamId = null;
    handFinished = false;
    isRoundAwaitingContinue = false;
    isTrucoAccepted = false;
    leadIndex = nextLeadIndex;
    nextLeadIndex = (nextLeadIndex + 1) % players.length;
    turnIndex = leadIndex;
    _resetPassedHandState();
    _refreshAlVerState();
    phase = 'playing';
    status = currentPlayerId == humanPlayerIds.first
        ? 'Sales tu.'
        : 'Sale ${currentPlayer.name}.';
    if (alVerState == AlVerState.awaitingDecision) {
      status = '$status Equipo al ver pendiente.';
      clearTurnDeadline();
    } else {
      refreshTurnDeadline();
    }
    stateVersion += 1;
  }

  void restartGame({Map<String, List<SpanishCard>>? fixedHands}) {
    score
      ..[1] = 0
      ..[2] = 0;
    nextLeadIndex = 0;
    winningTeamId = null;
    phase = 'playing';
    startNewHand(fixedHands: fixedHands);
  }

  MatchPlayer playerById(String playerId) {
    return players.firstWhere((player) => player.playerId == playerId);
  }

  void maybeAutoPlayBots() {
    if (alVerState == AlVerState.awaitingDecision) {
      final teamId = alVerTeamId;
      if (teamId != null && _teamHasOnlyBots(teamId)) {
        chooseAlVerDecision(teamId: teamId, play: _shouldBotPlayAlVer(teamId));
      }
      return;
    }

    while (!handFinished &&
        !isRoundAwaitingContinue &&
        !isGameFinished &&
        currentPlayer.isBot &&
        pendingTrucoValue == null) {
      final bot = currentPlayer;
      final card = chooseBotCard(bot);
      playCard(bot.playerId, card);
    }

    if (!handFinished &&
        !isRoundAwaitingContinue &&
        pendingTrucoValue != null &&
        trucoCallerTeamId != null) {
      final respondingTeamId = trucoResponseTeamId;
      if (_teamHasOnlyBots(respondingTeamId)) {
        acceptTruco(teamId: respondingTeamId);
      }
    }
  }

  bool teamHasOnlyBots(int teamId) => _teamHasOnlyBots(teamId);

  void refreshTurnDeadline({int? now}) {
    if (!isAwaitingCardPlay) {
      clearTurnDeadline();
      return;
    }
    final currentTime = now ?? DateTime.now().millisecondsSinceEpoch;
    turnDeadlineAt = currentTime + turnTimeoutSeconds * 1000;
  }

  void clearTurnDeadline() {
    turnDeadlineAt = null;
  }

  int? turnSecondsRemaining({int? now}) {
    final deadline = turnDeadlineAt;
    if (deadline == null) return null;
    final currentTime = now ?? DateTime.now().millisecondsSinceEpoch;
    final remainingMillis = deadline - currentTime;
    if (remainingMillis <= 0) return 0;
    return (remainingMillis / 1000).ceil();
  }

  PlayedCard playTimeoutCard({int? now}) {
    if (!isAwaitingCardPlay) {
      throw StateError('No card turn pending.');
    }
    final deadline = turnDeadlineAt;
    final currentTime = now ?? DateTime.now().millisecondsSinceEpoch;
    if (deadline != null && currentTime < deadline) {
      throw StateError('Turn timeout has not expired.');
    }
    final player = currentPlayer;
    final hand = hands[player.playerId];
    if (hand == null || hand.isEmpty) {
      throw StateError('Current player has no cards.');
    }
    final card = player.isBot
        ? chooseBotCard(player)
        : _chooseTimeoutCard(player);
    playCard(player.playerId, card);
    if (isAwaitingCardPlay) {
      refreshTurnDeadline(now: currentTime);
    }
    return PlayedCard(player: player, card: card);
  }

  MatchPlayer botResponderForTeam(int teamId) {
    return players.firstWhere(
      (player) => player.teamId == teamId && player.isBot,
    );
  }

  bool shouldBotPlayAlVer(int teamId) => _shouldBotPlayAlVer(teamId);

  bool shouldBotCallTruco(MatchPlayer bot) {
    if (!bot.isBot ||
        pendingTrucoValue != null ||
        isTrucoAccepted ||
        handFinished ||
        isRoundAwaitingContinue ||
        alVerState == AlVerState.awaitingDecision ||
        roundHistory.length >= 2 ||
        maxAllowedTrucoValue < TrucoRules.firstTrucoValue) {
      return false;
    }
    if (alVerState != AlVerState.none && alVerTeamIds.contains(bot.teamId)) {
      return false;
    }

    final teamScore = _teamHandScore(bot.teamId);
    final handStrength = _normalizedHandStrength(bot.teamId);
    final ownMaxStrength = _handMaxStrength(bot.playerId);
    final opponentTeamId = _opponentOf(bot.teamId);
    final canCloseHand = roundWins[bot.teamId]! > 0;
    final mustSaveHand = roundWins[opponentTeamId]! > 0;
    final needsPoints = score[bot.teamId]! < score[opponentTeamId]!;
    final profile = _BotDifficultyProfile.byLevel(bot.aiDifficulty);

    if (handStrength < 0.40) return false;
    if (mustSaveHand && handStrength < 0.65) return false;
    if (playedCards.isEmpty && !canCloseHand) {
      if (handStrength < 0.80 || teamScore < profile.threshold(165)) {
        return false;
      }
    } else if (canCloseHand) {
      if (teamScore < profile.threshold(94)) return false;
    } else if (needsPoints) {
      if (teamScore < profile.threshold(132)) return false;
    } else if (teamScore < profile.threshold(145)) {
      return false;
    }

    var chance = switch (profile.level) {
      <= 2 => handStrength >= 0.80 ? 0.16 : 0.07,
      3 => handStrength >= 0.80 ? 0.24 : 0.12,
      _ => handStrength >= 0.80 ? 0.34 : 0.18,
    };
    if (playedCards.isNotEmpty) chance += 0.03;
    if (canCloseHand) chance += 0.04;
    if (needsPoints) chance += 0.02;
    if (ownMaxStrength >= 97) chance += 0.02;

    return _decisionRandom('call_truco', bot).nextDouble() <
        chance.clamp(0, 0.48);
  }

  BotTrucoDecision chooseBotTrucoDecision(int teamId) {
    final responder = botResponderForTeam(teamId);
    final pendingValue = pendingTrucoValue;
    if (pendingValue == null) {
      throw StateError('No truco pending.');
    }

    final raiseValue = _chooseBotRaiseValue(responder, pendingValue);
    if (raiseValue != null) {
      return BotTrucoDecision(
        action: BotTrucoAction.raise,
        player: responder,
        value: raiseValue,
      );
    }

    final accepts = _shouldBotAcceptTruco(responder, pendingValue);
    return BotTrucoDecision(
      action: accepts ? BotTrucoAction.accept : BotTrucoAction.pass,
      player: responder,
    );
  }

  SpanishCard chooseBotCard(MatchPlayer bot) {
    final hand = hands[bot.playerId];
    if (hand == null || hand.isEmpty) {
      throw StateError('Bot has no cards.');
    }
    final sorted = [...hand]..sort(_compareByStrength);
    if (playedCards.isEmpty) {
      return sorted.first;
    }

    final bestTableStrength = playedCards
        .map((playedCard) => ZapitiRules.strength(playedCard.card))
        .reduce((best, current) => current > best ? current : best);
    final winningCards = sorted.where((card) {
      return ZapitiRules.strength(card) > bestTableStrength;
    }).toList();

    return winningCards.isNotEmpty ? winningCards.first : sorted.first;
  }

  void chooseAlVerDecision({required int teamId, required bool play}) {
    if (alVerState != AlVerState.awaitingDecision) {
      throw StateError('No al ver decision pending.');
    }
    if (!alVerTeamIds.contains(teamId)) {
      throw ArgumentError('Team $teamId is not al ver.');
    }
    if (alVerTeamIds.length != 1) {
      throw StateError('Both-team al ver is not supported yet.');
    }

    if (play) {
      alVerState = AlVerState.playing;
      status = 'Equipo $teamId decide jugar al ver. La mano continua.';
      refreshTurnDeadline();
      stateVersion += 1;
      return;
    }

    final rivalTeamId = teamId == 1 ? 2 : 1;
    alVerState = AlVerState.conceded;
    _finishHandForTeam(rivalTeamId, points: 2);
    stateVersion += 1;
  }

  Map<String, dynamic> toPublicJson() => {
    'roomId': roomId,
    'phase': phase,
    'createdAt': createdAt,
    'seed': seed,
    'handSequence': handSequence,
    'stateVersion': stateVersion,
    'players': [for (final player in players) player.toJson()],
    'currentPlayerId': currentPlayerId,
    'leadPlayerId': players[leadIndex].playerId,
    'nextLeadPlayerId': players[nextLeadIndex].playerId,
    'allowPassHand': allowPassHand,
    'passedHandState': passedHandState.toJson(),
    'handValue': handValue,
    'betState': betState.toJson(),
    'pendingTrucoValue': pendingTrucoValue,
    'trucoCallerTeamId': trucoCallerTeamId,
    'lastTrucoRaiserTeamId': lastTrucoRaiserTeamId,
    'isTrucoAccepted': isTrucoAccepted,
    'score': {'1': score[1], '2': score[2]},
    'roundWins': {'1': roundWins[1], '2': roundWins[2]},
    'turnIndex': turnIndex,
    'leadIndex': leadIndex,
    'nextLeadIndex': nextLeadIndex,
    'playedCards': [
      for (final playedCard in playedCards)
        {
          'playerId': playedCard.player.playerId,
          'card': playedCard.card.toJson(),
        },
    ],
    'hands': {
      for (final entry in hands.entries)
        entry.key: [for (final card in entry.value) card.toJson()],
    },
    'handFinished': handFinished,
    'isRoundAwaitingContinue': isRoundAwaitingContinue,
    'winningTeamId': winningTeamId,
    'turnTimeoutSeconds': turnTimeoutSeconds,
    'turnDeadlineAt': turnDeadlineAt,
    'turnSecondsRemaining': turnSecondsRemaining(),
    'alVerState': alVerState.name,
    'alVerTeamId': alVerTeamId,
    'alVerTeamIds': alVerTeamIds.toList(),
    'status': status,
  };

  bool _teamHasOnlyBots(int teamId) {
    final teamPlayers = players.where((player) => player.teamId == teamId);
    return teamPlayers.isNotEmpty &&
        teamPlayers.every((player) => player.isBot);
  }

  void _applyProgress(HandProgress progress) {
    roundWins
      ..[1] = progress.roundWinsFor(1)
      ..[2] = progress.roundWinsFor(2);
  }

  void _handleWonRound(RoundResult result, HandProgress progress) {
    final winner = result.winner!;
    final winningTeam = winner.player.teamId;
    leadIndex = players.indexWhere(
      (player) => player.playerId == winner.player.playerId,
    );
    turnIndex = leadIndex;

    if (progress.isFinished && progress.winningTeamId != null) {
      _finishHandForTeam(progress.winningTeamId!);
      return;
    }

    _resetPassedHandState();
    status =
        '${winner.player.name} gana con ${winner.card}. Ronda para Equipo $winningTeam.';
  }

  void _handleTiedRound(int roundNumber, HandProgress progress) {
    if (progress.isNoPoints) {
      _finishHandWithoutPoints();
      return;
    }

    if (progress.isFinished && progress.winningTeamId != null) {
      _finishHandForTeam(progress.winningTeamId!);
      return;
    }

    turnIndex = leadIndex;
    _resetPassedHandState();
    status = roundNumber == 1
        ? 'Primera ronda empatada.'
        : 'Primera y segunda ronda empatadas.';
  }

  void _resetPassedHandState() {
    passedHandState = PassedHandState(
      originalLeaderId: players[leadIndex].playerId,
    );
  }

  void _finishHandForTeam(int teamId, {int? points}) {
    final awardedPoints = points ?? handValue;
    score[teamId] = (score[teamId]! + awardedPoints).clamp(0, targetScore);
    handFinished = true;
    isRoundAwaitingContinue = false;
    pendingTrucoValue = null;
    clearTurnDeadline();
    trucoCallerTeamId = null;
    if (score[teamId]! >= targetScore) {
      winningTeamId = teamId;
      phase = 'finished';
      status = 'Equipo $teamId gana la partida.';
    } else {
      status = 'Equipo $teamId gana la mano y suma $awardedPoints.';
    }
  }

  void _finishHandWithoutPoints() {
    handFinished = true;
    isRoundAwaitingContinue = false;
    clearTurnDeadline();
    pendingTrucoValue = null;
    trucoCallerTeamId = null;
    status = 'Mano sin puntos.';
  }

  int _compareByStrength(SpanishCard a, SpanishCard b) {
    return ZapitiRules.strength(a).compareTo(ZapitiRules.strength(b));
  }

  SpanishCard _chooseTimeoutCard(MatchPlayer player) {
    final hand = hands[player.playerId];
    if (hand == null || hand.isEmpty) {
      throw StateError('Player has no cards.');
    }
    final sorted = [...hand]..sort(_compareByStrength);
    return sorted.first;
  }

  int _teamHandScore(int teamId) {
    final strengths =
        players
            .where((player) => player.teamId == teamId)
            .expand((player) => hands[player.playerId] ?? const <SpanishCard>[])
            .map(ZapitiRules.strength)
            .toList()
          ..sort();
    if (strengths.isEmpty) return 0;
    final strongest = strengths.last;
    final second = strengths.length > 1
        ? strengths[strengths.length - 2] ~/ 2
        : 0;
    final third = strengths.length > 2
        ? strengths[strengths.length - 3] ~/ 3
        : 0;
    return strongest + second + third;
  }

  double _normalizedHandStrength(int teamId) {
    final strengths =
        players
            .where((player) => player.teamId == teamId)
            .expand((player) => hands[player.playerId] ?? const <SpanishCard>[])
            .map(ZapitiRules.strength)
            .toList()
          ..sort();
    if (strengths.isEmpty) return 0;
    final strongest = strengths.last / 100;
    final second = strengths.length > 1
        ? strengths[strengths.length - 2] / 100
        : 0;
    final third = strengths.length > 2
        ? strengths[strengths.length - 3] / 100
        : 0;
    return (strongest * 0.55 + second * 0.30 + third * 0.15).clamp(0, 1);
  }

  int _handMaxStrength(String playerId) {
    final playerHand = hands[playerId] ?? const <SpanishCard>[];
    if (playerHand.isEmpty) return 0;
    return playerHand
        .map(ZapitiRules.strength)
        .reduce((best, current) => current > best ? current : best);
  }

  int? _chooseBotRaiseValue(MatchPlayer responder, int pendingValue) {
    if (pendingValue >= maxAllowedTrucoValue || pendingValue >= 9) return null;

    final profile = _BotDifficultyProfile.byLevel(responder.aiDifficulty);
    final teamId = responder.teamId;
    final teamScore = _teamHandScore(teamId);
    final strengths =
        players
            .where((player) => player.teamId == teamId)
            .expand((player) => hands[player.playerId] ?? const <SpanishCard>[])
            .map(ZapitiRules.strength)
            .toList()
          ..sort();
    if (strengths.isEmpty) return null;

    final strongest = strengths.last;
    final goodCards = strengths.where((strength) => strength >= 80).length;
    final isWinningReparto =
        roundWins[teamId]! > roundWins[_opponentOf(teamId)]!;
    if (strongest < 90 && goodCards < 2) return null;
    if (!isWinningReparto && pendingValue >= 6 && goodCards < 2) return null;
    if (teamScore < profile.threshold(pendingValue >= 6 ? 128 : 145)) {
      return null;
    }

    var chance = switch (profile.level) {
      <= 2 => 0.06,
      3 => 0.12,
      _ => 0.20,
    };
    if (strongest >= 97) chance += 0.06;
    if (goodCards >= 2) chance += 0.05;
    if (isWinningReparto) chance += 0.03;
    if (pendingValue >= 6) chance *= 0.5;

    if (_decisionRandom('raise_truco', responder).nextDouble() >=
        chance.clamp(0, 0.32)) {
      return null;
    }

    final nextValue = pendingValue + TrucoRules.raiseStep;
    return nextValue <= maxAllowedTrucoValue ? nextValue : null;
  }

  bool _shouldBotAcceptTruco(MatchPlayer responder, int pendingValue) {
    if (pendingValue > maxAllowedTrucoValue) return false;

    final teamId = responder.teamId;
    final opponentTeamId = _opponentOf(teamId);
    final profile = _BotDifficultyProfile.byLevel(responder.aiDifficulty);
    final teamScore = _teamHandScore(teamId);
    final handStrength = _normalizedHandStrength(teamId);
    final strongest = players
        .where((player) => player.teamId == teamId)
        .map((player) => _handMaxStrength(player.playerId))
        .fold(0, (best, current) => current > best ? current : best);

    var threshold = switch (pendingValue) {
      <= 3 => 100,
      <= 6 => 122,
      <= 9 => 144,
      _ => 162,
    };
    threshold = profile.threshold(threshold);
    if (roundWins[teamId]! > roundWins[opponentTeamId]!) threshold -= 14;
    if (roundWins[opponentTeamId]! > roundWins[teamId]!) threshold += 8;
    if (score[teamId]! < score[opponentTeamId]!) threshold -= 6;
    if (score[opponentTeamId]! >= targetScore - 3) threshold -= 8;
    if (strongest >= 97) threshold -= 8;
    if (handStrength < 0.35 && pendingValue >= 6) threshold += 10;

    final acceptsByStrength = teamScore >= threshold;
    if (acceptsByStrength) return true;

    final impulseChance = switch (profile.level) {
      1 => 0.16,
      2 => 0.08,
      3 => 0.025,
      _ => 0.0,
    };
    return _decisionRandom('accept_truco', responder).nextDouble() <
        impulseChance;
  }

  Random _decisionRandom(String salt, MatchPlayer player) {
    var value =
        seed ^
        handSeed ^
        (handSequence * 1009) ^
        (playedCards.length * 37) ^
        (roundHistory.length * 101) ^
        ((pendingTrucoValue ?? 0) * 211);
    for (final unit in '$salt:${player.playerId}'.codeUnits) {
      value = (value * 31 + unit) & 0x7fffffff;
    }
    return Random(value);
  }

  int _opponentOf(int teamId) => teamId == 1 ? 2 : 1;

  Map<String, List<SpanishCard>> _dealRandomHands() {
    final deck = ZapitiDeck.shuffled(random: Random(handSeed));
    return {
      for (var i = 0; i < players.length; i++)
        players[i].playerId: deck.skip(i * 3).take(3).toList(),
    };
  }

  Map<String, List<SpanishCard>> _cloneHands(
    Map<String, List<SpanishCard>> source,
  ) {
    return {
      for (final entry in source.entries) entry.key: [...entry.value],
    };
  }

  void _refreshAlVerState() {
    alVerTeamIds.clear();
    if (score[1] == 29) {
      alVerTeamIds.add(1);
    }
    if (score[2] == 29) {
      alVerTeamIds.add(2);
    }
    alVerState = alVerTeamIds.isEmpty
        ? AlVerState.none
        : AlVerState.awaitingDecision;
  }

  bool _shouldBotPlayAlVer(int teamId) {
    final cards =
        hands[players.firstWhere((player) => player.teamId == teamId).playerId];
    if (cards == null || cards.isEmpty) return false;

    final strengths = cards.map(ZapitiRules.strength).toList()..sort();
    final strongest = strengths.last;
    final second = strengths.length > 1 ? strengths[strengths.length - 2] : 0;
    final third = strengths.length > 2 ? strengths[strengths.length - 3] : 0;
    final handScore = strongest + (second ~/ 2) + (third ~/ 3);
    final opponentTeamId = teamId == 1 ? 2 : 1;
    final scoreGap = score[teamId]! - score[opponentTeamId]!;

    var threshold = 104;
    if (scoreGap < 0) {
      threshold -= 10;
    } else if (scoreGap >= 6) {
      threshold += 8;
    }
    if (score[opponentTeamId]! >= targetScore - 2) {
      threshold -= 12;
    }
    if (score[teamId]! >= targetScore - 1) {
      threshold += 6;
    }
    if (strongest >= 97) {
      threshold -= 6;
    }
    return handScore >= threshold;
  }
}

class _BotDifficultyProfile {
  final int level;
  final int callThresholdModifier;

  const _BotDifficultyProfile({
    required this.level,
    required this.callThresholdModifier,
  });

  int threshold(int base) => base + callThresholdModifier;

  static _BotDifficultyProfile byLevel(int level) {
    return switch (level.clamp(1, 5)) {
      1 => const _BotDifficultyProfile(level: 1, callThresholdModifier: -8),
      2 => const _BotDifficultyProfile(level: 2, callThresholdModifier: -4),
      3 => const _BotDifficultyProfile(level: 3, callThresholdModifier: -2),
      4 => const _BotDifficultyProfile(level: 4, callThresholdModifier: 8),
      _ => const _BotDifficultyProfile(level: 5, callThresholdModifier: 10),
    };
  }
}
