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
  final int aiDifficulty;

  const MatchPlayer({
    required this.playerId,
    required this.name,
    required this.teamId,
    this.connectionId,
    required this.characterId,
    this.aiDifficulty = 3,
  });

  bool get isBot => connectionId == null;

  Map<String, dynamic> toJson() => {
        'playerId': playerId,
        'name': name,
        'teamId': teamId,
        'characterId': characterId,
        if (isBot) 'aiDifficulty': aiDifficulty,
      };
}

enum BotTrucoAction {
  accept,
  pass,
  raise,
}

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
    final maxValue =
        maxForTeamOne < maxForTeamTwo ? maxForTeamOne : maxForTeamTwo;
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

  static int passPoints({required int currentAcceptedValue}) {
    return currentAcceptedValue;
  }
}

enum AlVerState {
  none,
  awaitingDecision,
  playing,
  conceded,
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
  final Set<int> alVerTeamIds = {};

  int turnIndex = 0;
  int leadIndex = 0;
  int nextLeadIndex = 0;
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
  int? get alVerTeamId =>
      alVerTeamIds.length == 1 ? alVerTeamIds.first : null;
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
    if (alVerState == AlVerState.awaitingDecision) {
      throw StateError('Al ver pending.');
    }
    if (alVerState != AlVerState.none && alVerTeamIds.contains(player.teamId)) {
      throw StateError('Team al ver cannot call truco.');
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
    if (alVerState == AlVerState.awaitingDecision) {
      throw StateError('Al ver pending.');
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
    if (alVerState == AlVerState.awaitingDecision) {
      throw StateError('Al ver pending.');
    }
    final player = playerById(playerId);
    if (alVerState != AlVerState.none && alVerTeamIds.contains(player.teamId)) {
      throw StateError('Team al ver cannot raise truco.');
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
    if (alVerState == AlVerState.awaitingDecision) {
      throw StateError('Al ver pending.');
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
    _refreshAlVerState();
    phase = 'playing';
    status = currentPlayerId == humanPlayerIds.first
        ? 'Sales tu.'
        : 'Sale ${currentPlayer.name}.';
    if (alVerState == AlVerState.awaitingDecision) {
      status = '$status Equipo al ver pendiente.';
    }
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
      return;
    }

    final rivalTeamId = teamId == 1 ? 2 : 1;
    alVerState = AlVerState.conceded;
    _finishHandForTeam(
      rivalTeamId,
      points: 2,
    );
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

  int _teamHandScore(int teamId) {
    final strengths = players
        .where((player) => player.teamId == teamId)
        .expand((player) => hands[player.playerId] ?? const <SpanishCard>[])
        .map(ZapitiRules.strength)
        .toList()
      ..sort();
    if (strengths.isEmpty) return 0;
    final strongest = strengths.last;
    final second =
        strengths.length > 1 ? strengths[strengths.length - 2] ~/ 2 : 0;
    final third =
        strengths.length > 2 ? strengths[strengths.length - 3] ~/ 3 : 0;
    return strongest + second + third;
  }

  double _normalizedHandStrength(int teamId) {
    final strengths = players
        .where((player) => player.teamId == teamId)
        .expand((player) => hands[player.playerId] ?? const <SpanishCard>[])
        .map(ZapitiRules.strength)
        .toList()
      ..sort();
    if (strengths.isEmpty) return 0;
    final strongest = strengths.last / 100;
    final second =
        strengths.length > 1 ? strengths[strengths.length - 2] / 100 : 0;
    final third =
        strengths.length > 2 ? strengths[strengths.length - 3] / 100 : 0;
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
    final strengths = players
        .where((player) => player.teamId == teamId)
        .expand((player) => hands[player.playerId] ?? const <SpanishCard>[])
        .map(ZapitiRules.strength)
        .toList()
      ..sort();
    if (strengths.isEmpty) return null;

    final strongest = strengths.last;
    final goodCards = strengths.where((strength) => strength >= 80).length;
    final isWinningReparto = roundWins[teamId]! > roundWins[_opponentOf(teamId)]!;
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
    var value = seed ^
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
    final cards = hands[players
        .firstWhere((player) => player.teamId == teamId)
        .playerId];
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
