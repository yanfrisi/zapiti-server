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

  const SpanishCard({
    required this.value,
    required this.suit,
  });

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

  Map<String, dynamic> toJson() => {
        'value': value,
        'suit': suit.label,
      };

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
  final String characterId;

  const MatchPlayer({
    required this.playerId,
    required this.name,
    required this.teamId,
    this.connectionId,
    required this.characterId,
  });

  bool get isBot => connectionId == null;

  Map<String, dynamic> toJson() => {
        'playerId': playerId,
        'name': name,
        'teamId': teamId,
        'characterId': characterId,
      };
}

class PlayedCard {
  final MatchPlayer player;
  final SpanishCard card;

  const PlayedCard({
    required this.player,
    required this.card,
  });
}

class RoundResult {
  final PlayedCard? winner;
  final List<PlayedCard> playedCards;

  const RoundResult({
    required this.winner,
    required this.playedCards,
  });

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

    final PlayedCard? winner =
        strongestTeams.length == 1 ? strongestCards.first : null;
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

  static int maxAllowedValue({
    required int scoreTeamOne,
    required int scoreTeamTwo,
    required int targetScore,
    required int currentAcceptedValue,
  }) {
    final maxForTeamOne = targetScore - 1 - scoreTeamOne;
    final maxForTeamTwo = targetScore - 1 - scoreTeamTwo;
    final maxValue =
        maxForTeamOne < maxForTeamTwo ? maxForTeamOne : maxForTeamTwo;
    return maxValue < currentAcceptedValue ? currentAcceptedValue : maxValue;
  }

  static List<int> raiseOptions({
    required int pendingValue,
    required int maxAllowedValue,
  }) {
    final firstRaise = pendingValue + 1;
    if (firstRaise > maxAllowedValue) return const [];
    return [
      for (var value = firstRaise; value <= maxAllowedValue; value++) value
    ];
  }

  static int passPoints({required int currentAcceptedValue}) {
    return currentAcceptedValue;
  }
}

class MatchState {
  static const defaultTargetScore = 30;

  final String roomId;
  final int createdAt;
  final int targetScore;
  final int seed;
  final List<MatchPlayer> players;
  int handSequence = 0;
  int handSeed;
  final Map<String, List<SpanishCard>> hands;
  final List<PlayedCard> playedCards = [];
  final List<RoundResult> roundHistory = [];
  final Map<int, int> score = {1: 0, 2: 0};
  final Map<int, int> roundWins = {1: 0, 2: 0};

  int turnIndex = 0;
  int leadIndex = 0;
  int nextLeadIndex = 0;
  int handValue = 1;
  int? pendingTrucoValue;
  int? trucoCallerTeamId;
  int? lastTrucoRaiserTeamId;
  int? winningTeamId;
  bool handFinished = false;
  bool isRoundAwaitingContinue = false;
  bool isTrucoAccepted = false;
  String phase = 'playing';
  String status = '';

  MatchState._({
    required this.roomId,
    required this.createdAt,
    required this.targetScore,
    required this.seed,
    required this.players,
    required this.handSeed,
    required this.hands,
  });

  factory MatchState.start({
    required String roomId,
    required int createdAt,
    required int seed,
    required List<MatchPlayer> players,
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
      handSeed: seed,
      hands: dealtHands,
    );
    state.leadIndex = state.nextLeadIndex;
    state.turnIndex = state.leadIndex;
    state.status = state.currentPlayerId == state.humanPlayerIds.first
        ? 'Sales tu.'
        : 'Sale ${state.currentPlayer.name}.';
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
  int get trucoResponseTeamId {
    final callerTeamId = trucoCallerTeamId;
    if (callerTeamId == null) {
      throw StateError('No truco caller.');
    }
    return callerTeamId == 1 ? 2 : 1;
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
      return;
    }

    turnIndex = (turnIndex + 1) % players.length;
    status = 'Turno de ${currentPlayer.name}.';
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
  }

  void continueRound() {
    if (!isRoundAwaitingContinue) return;
    playedCards.clear();
    isRoundAwaitingContinue = false;
    status = 'Turno de ${currentPlayer.name}.';
  }

  void callTruco(String playerId, {required int value}) {
    final player = playerById(playerId);
    if (value > maxAllowedTrucoValue) {
      throw ArgumentError('Truco value too high.');
    }
    pendingTrucoValue = value;
    trucoCallerTeamId = player.teamId;
    lastTrucoRaiserTeamId = player.teamId;
    isTrucoAccepted = false;
    status =
        '${player.name} sube el reparto a $value. El otro equipo debe responder.';
  }

  void acceptTruco({required int teamId}) {
    final acceptedValue = pendingTrucoValue;
    if (acceptedValue == null) {
      throw StateError('No truco pending.');
    }
    handValue = acceptedValue;
    pendingTrucoValue = null;
    trucoCallerTeamId = null;
    isTrucoAccepted = true;
    status = 'Equipo $teamId acepta. El reparto vale $handValue.';
  }

  void raiseTruco(String playerId, {required int value}) {
    final pending = pendingTrucoValue;
    if (pending == null) {
      throw StateError('No truco pending.');
    }
    if (value <= pending) {
      throw ArgumentError('Raise must be higher.');
    }
    handValue = pending;
    callTruco(playerId, value: value);
  }

  void passTruco({required int passingTeamId}) {
    final callerTeamId = trucoCallerTeamId;
    if (callerTeamId == null || pendingTrucoValue == null) {
      throw StateError('No truco pending.');
    }
    if (passingTeamId == callerTeamId) {
      throw ArgumentError('Caller team cannot pass itself.');
    }
    final points = TrucoRules.passPoints(currentAcceptedValue: handValue);
    _finishHandForTeam(callerTeamId, points: points);
  }

  void startNewHand({Map<String, List<SpanishCard>>? fixedHands}) {
    if (isGameFinished) {
      throw StateError('Game already finished.');
    }

    handSequence += 1;
    if (fixedHands == null) {
      handSeed = DateTime.now().microsecondsSinceEpoch ^
          Random().nextInt(1 << 32) ^
          handSequence;
    }
    hands
      ..clear()
      ..addAll(
          fixedHands == null ? _dealRandomHands() : _cloneHands(fixedHands));
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
    phase = 'playing';
    status = currentPlayerId == humanPlayerIds.first
        ? 'Sales tu.'
        : 'Sale ${currentPlayer.name}.';
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

  Map<String, dynamic> toPublicJson() => {
        'roomId': roomId,
        'phase': phase,
        'createdAt': createdAt,
        'seed': seed,
        'handSequence': handSequence,
        'players': [for (final player in players) player.toJson()],
        'currentPlayerId': currentPlayerId,
        'leadPlayerId': players[leadIndex].playerId,
        'nextLeadPlayerId': players[nextLeadIndex].playerId,
        'handValue': handValue,
        'pendingTrucoValue': pendingTrucoValue,
        'trucoCallerTeamId': trucoCallerTeamId,
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
            }
        ],
        'hands': {
          for (final entry in hands.entries)
            entry.key: [for (final card in entry.value) card.toJson()],
        },
        'handFinished': handFinished,
        'isRoundAwaitingContinue': isRoundAwaitingContinue,
        'winningTeamId': winningTeamId,
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
    leadIndex = players
        .indexWhere((player) => player.playerId == winner.player.playerId);
    turnIndex = leadIndex;

    if (progress.isFinished && progress.winningTeamId != null) {
      _finishHandForTeam(progress.winningTeamId!);
      return;
    }

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
    status = roundNumber == 1
        ? 'Primera ronda empatada.'
        : 'Primera y segunda ronda empatadas.';
  }

  void _finishHandForTeam(int teamId, {int? points}) {
    final awardedPoints = points ?? handValue;
    score[teamId] = (score[teamId]! + awardedPoints).clamp(0, targetScore);
    handFinished = true;
    isRoundAwaitingContinue = false;
    pendingTrucoValue = null;
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
    pendingTrucoValue = null;
    trucoCallerTeamId = null;
    status = 'Mano sin puntos.';
  }

  int _compareByStrength(SpanishCard a, SpanishCard b) {
    return ZapitiRules.strength(a).compareTo(ZapitiRules.strength(b));
  }

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
}
