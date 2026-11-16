<!-- TEST-FIX 16.11.: Beispielnamen neutralisiert, Prüflogik unverändert -->
# Szenario-Abnahmetests (Ereignisse mal Betriebsarten)

Auftrag (diktiert): aufnehmen während einer Aufnahme, ein Call, mehrere Funktionen gleichzeitig gedrückt,
alle Error-Handles, abgebrochene Sachen müssen richtig wiederholt werden, Stiftaufnahmen richtig angezeigt.
Maßstab: `docs/ARCHITEKTUR.md` B.5 (Gleichzeitigkeit), A.4, A.10, A.11, M.5; `docs/ABNAHME.md` R-022, R-039, R-042,
R-043, R-062, R-072, R-098.

Stand: geschrieben, nur mit `swiftc -parse` auf Syntax geprüft. **Nichts gebaut, nichts gelaufen**, `Package.swift` und
`Sources/` unberührt. Jede Zeile, die eine offene API-Form berührt, trägt `// ASSUMPTION:` in derselben Zeile (37
Stück, die meisten in `SzenarienSupport.swift`, der Rest in den Tests, wo sie eine Naht benutzen). Der Bau-Agent darf nur diese Zeilen
ändern. Erwartete Werte bleiben unverändert; ein falscher Wert geht an den Auftraggeber.

## Test-Target (noch einzutragen, Package.swift gehört den Bau-Agenten)

```swift
.testTarget(name: "FlowIQSzenarienTests",
            dependencies: [core, log, "FlowIQAudio", "FlowIQRecording", "FlowIQInput", "FlowIQInsert", "FlowIQSpeech",
                           "FlowIQStore", "FlowIQText", "FlowIQDevices", "FlowIQCloud", "FlowIQ"],
            path: "abnahme-tests/szenarien", exclude: ["README.md"], swiftSettings: strict),
```

## Was echt läuft, was künstlich ist

Echt: `AudioConductor`, `Fanout`, `TrackWriter`, `RecordingSession`, `Rescue`, `RecordingLock`, `BusyState`,
`InputService`, `GestureMachine`, `FlowCoordinator`, `Inserter`, `DictationJournal`, `TranscriptStore`, `LiveTranscript`,
`Aftercare`, `PostQueue`, `DeviceImporter`, `ImportJournal`, `LiveSession`, `Recorder` (RecorderStartTests),
`AppModel.alerts`, `StatusMenuModel`, `PillScene`. Künstlich (Naht): Aufnahmequellen (`SzSource`), Tasten
(`SyntheticKeySource`), Erkenner (`StubRecognizer`), Textstufe, Zwischenablage, Ziel-App, Nachlauf-Dienst (`FakePost`
mit Skript), Stift (ein Ordner mit erzeugten WAV-Dateien, nie ein Volume, nie ein echter Gerätename), freier Platz
(Closure), Zeit (eine virtuelle Uhr `ManualClock` für Diktat und Einfügen, `TestClock` für den Nachlauf). Kein Mikrofon,
keine Taste, kein Netz, keine Berechtigung, kein `local/`.

Dateien: `SzenarienSupport.swift` (die eine Support-Datei, Fixtures aus p3, p4, p5 und `Tests/FlowIQDevicesTests` verkleinert
übernommen, weil jedes Target ein eigenes Modul ist), `GleichzeitigkeitTests`, `KurzbefehlTests`, `RecorderStartTests`,
`FehlerAufnahmeTests`, `WiederholenTests`, `StiftImportTests`, `AnzeigeTests`.

## Matrix: Ereignis mal Betriebsart (Zelle = Testname)

Die Betriebsart ist die Spalte, in der der Fall passiert. `Raum + Call` heißt beide Aufnahmen laufen auf einem Mikrofon.
`–` heißt: kommt in dieser Betriebsart nicht vor. Ein Testname mit `[...]` ist parametrisiert, die Klammer nennt die Fälle.

### 1. Gleichzeitigkeit

| Ereignis | Diktat | Call | Raum | Raum + Call | Import (Stift) |
|---|---|---|---|---|---|
| Diktat während Aufnahme | – | `dictationDuringARecordingSharesTheRunningDevice [call]` | `dictationDuringARecordingSharesTheRunningDevice [room]` | `threeStartsInsideFiftyMillisecondsShareOneDeviceAndLoseNothing` | – |
| Raum plus Call, ein Mikrofon, beide Spuren vollständig | – | – | – | `roomPlusCallShareOneMicrophoneAndBothTracksAreComplete [room, call]`, `aMicrophoneChangeInTheMenuAppliesToRoomAndCallWithoutAHole`, `roomAndCallThroughTheRecorderShareOneMicrophone` | – |
| Call starten während Call läuft | – | `startingACallWhileTheSameCallRunsOpensNothingNew`, `startingARunningKindAgainIsNotASecondRecording`, `aRunningKindHasNoStartRowOnlyItsStop` | `aRunningKindHasNoStartRowOnlyItsStop` (Menü, beide Arten), `twoStartsAtTheSameInstantAreOneRecording [room]` | – | – |
| Call DE, sofort Call EN | – | `callGermanThenCallEnglishRightAwayStaysOneGermanCall [false, true]` | – | – | – |
| Start und Stopp schnell (Prellen) | `theGestureMachineAnswersChatterAndFastGesturesCorrectly`, `chatterOnPressThroughTheInputServiceIsOneStartAndOnePill` | `twoStartsAtTheSameInstantAreOneRecording [call]` | `twoStartsAtTheSameInstantAreOneRecording [room]` | – | – |
| Fn während Start einer Aufnahme | – | `fnDuringTheStartOfARecordingJoinsTheOpeningMicrophone [call]` | `fnDuringTheStartOfARecordingJoinsTheOpeningMicrophone [room]` | `threeStartsInsideFiftyMillisecondsShareOneDeviceAndLoseNothing [fn, call, room]` | – |
| Drei Kurzbefehle in 50 ms | `recordingShortcutsDuringADictationNeverDisturbIt` | `threeStartsInsideFiftyMillisecondsShareOneDeviceAndLoseNothing` (3 Reihenfolgen) | idem | idem | – |
| Diktat gesperrt (Fn Fn) plus Call-Stopp | `aLockedDictationAndTheStopOfACallNeverStopTheSharedMicrophone [callFirst, dictationFirst]` | idem | – | – | – |
| Import läuft während Diktat und Aufnahme | `importRunsThrottledWhileADictationAndACallRunAndLosesNothing` | idem | – | – | idem (gedrosselt, 3 Dateien, kein Verlust) |

### 2. Fehler und Wiederholen

| Ereignis | Diktat | Call | Raum | Raum + Call | Import (Stift) |
|---|---|---|---|---|---|
| Mikrofon verweigert | `aRefusedMicrophoneLeavesNothingBehindAndTheNextTryWorks [dictation]`, `aRefusedMicrophoneDoesNotLeaveTheGestureStuck` | `... [call]` | `... [room]` | – | – |
| Gerät verschwindet mitten in der Aufnahme (AirPods weg) | `aDeviceThatVanishesInTheMiddleOfADictationCostsNoText` | `aVanishingDeviceFallsBackWithinOneSecondAndFillsTheGap [call]` | `... [room]`, `withoutAReplacementDeviceTheTrackIsFilledAndTheReturnIsShown` | `aMicrophoneChangeInTheMenuAppliesToRoomAndCallWithoutAHole` (Wechsel im Menü, nicht Verlust) | – |
| Desktop-Strom endet | – | `whenTheDesktopStreamEndsTheCallRunsOnAndTheStreamComesBack`, `ifTheDesktopDoesNotComeBackTheFirstFailedAttemptIsShown` | – | – | – |
| Platte voll | `aDictationThatCannotStoreItsAudioStillInsertsTheText` | `lessThanOneGigabyteWarnsAndTheRecordingGoesOn`, `lessThanTwoHundredMegabytesEndsTheRecordingCleanlyWithTheAudioKept` (langsam, 10 s Echtzeit) | `anUnreadableFreeSpaceAnswerIsLoggedOnceAndTheRecordingGoesOn` | – | – (Import schreibt nur in den Archivordner, Schwelle dort nicht vorgesehen) |
| Live-Erkenner wirft beim Start und mittendrin | – | `aFailingLiveRecognizerNeverStopsTheRecording [atStart, inTheMiddle] [call]` | `... [room]` | – | – |
| Nachlauf scheitert: Netz weg, Kontingent leer, leeres Ergebnis; genau einmal wiederholt | – (Nachlauf für Diktat: Pfad wie Call, `Aftercare.dictationInserted`, hier nicht eigens) | `aFailedAftercareIsTriedAgainExactlyOnceWhenItCanRun [call]`, `quotaOrKeyPausesTheJobUntilAClickOrTheNextDay`, `anEmptyResultThreeTimesWaitsForAClick` (Raum) | `aFailedAftercareIsTriedAgainExactlyOnceWhenItCanRun [room]`, `anEmptyResultThreeTimesWaitsForAClick` | – | `aFailedFileShowsTheRetryAndTheRetryRunsOnlyThatFile` (Erkennung scheitert, Wiederholung nur für diese Datei) |
| App-Neustart mitten in Aufnahme | `aDictationCutOffInTheMiddleLeavesAudioAndAJournalEntryToRetryFrom` | `anAppRestartInTheMiddleOfACallRescuesTheAudioAndTheLiveFileOnce` | (derselbe Pfad, Raum hat eine Spur weniger) | – | – |
| App-Neustart mitten im Nachlauf | – | `anAppRestartInTheMiddleOfTheAftercareRunsTheJobOnceAfterwards` | idem | – | – |
| App-Neustart mitten im Import | – | – | – | – | `anAppRestartInTheMiddleOfTheCopyImportsTheFileOnce`, `anAppRestartInTheMiddleOfTheRecognitionDoesNotCopyAgain` |
| Stift während des Kopierens abgezogen | – | – | – | – | `aPenUnpluggedDuringTheCopyIsContinuedAtTheNextPlugInWithoutAHalfFile` |
| Beschädigte Stiftdatei | – | – | – | – | `aDamagedPenFileIsReportedAndTheOthersRunOn` |

### 3. Anzeige (`AnzeigeTests`)

| Fall | Sichtbarer Zustand | Test |
|---|---|---|
| Mikrofon-Recht fehlt, Desktop fehlt, Mikrofon still, Netz weg, Monatsgrenze, Nachlauf wartet, Nachlauf angehalten, kein Textfeld, Ordner fehlt, Tap steht | genau eine Warnzeile mit Text und nächstem Schritt, im Menü oben mit Trenner | `everyCaseShowsItsOneWarningWithItsNextStep`, `theMenuShowsTheWarningAtTheTopWithItsStep` (je 10 Fälle) |
| mehrere Warnungen zugleich | feste Reihenfolge | `severalWarningsComeInAFixedOrder` |
| jede Warnung hat einen nächsten Schritt | Text plus Schritt | `everyWarningNamesItsNextStep` (erwartet rot, siehe unten) |
| Desktop weg ist kein stilles Mikrofon | nur `noDesktop` | `aDesktopThatIsDownIsNotReportedAsASilentMicrophone` (erwartet rot) |
| Call läuft: keine zweite Start-Zeile, Stopp-Zeile da | Menü | `aRunningKindHasNoStartRowOnlyItsStop` |
| Raum plus Call: ein Gerät in beiden Zeilen, Rückfall lokal, Cloud sendet | Menü | `roomPlusCallNameOneDeviceAndTheCloudState` |
| Raum plus Call: zwei Pillen, Kopfhörer-Marke, nur Aufnahme-Pillen klickbar | Pille | `roomPlusCallShowTwoPillsAndTheSharedMicrophoneMark` |
| Diktat während Call oder Raum, gesperrt mit Punkt | Pille | `aDictationDuringARecordingShowsBothPills [call, room]` |
| stille Spur: Alarm-Marke an der Pille; Desktop weg: keine | Pille | `aSilentMicrophoneIsAnAlarmMarkAtItsPill` |
| EN und verlorene Cloud als Marken | Pille | `englishAndTheLostCloudAreMarksAtThePill` |
| Diktat fehlgeschlagen oder ohne Textfeld | Alarm-Marke, Zwischenablage-Marke | `aFailedOrNotInsertedDictationLeavesAMarkNotJustNothing` |
| Import-Ring: Anteil, Puls, weg, auch während Aufnahme | Pille | `theImportRingShowsAtThePillAlsoDuringARecording` |
| Stift je Datei: wartet, kopiert, erkannt, abgelegt | Liste | `everyFileShowsItsStatesInOrderAndTheRingRisesOverTheWholeImport` |
| Stift: fehlgeschlagen mit "Erneut versuchen" | Liste | `aFailedFileShowsTheRetryAndTheRetryRunsOnlyThatFile` |
| Live-Erkennung aus | eine kursive Zeile in der Datei mit "Text nach dem Stopp" | `aFailedLiveRecognizerIsOneVisibleLineInTheFile [recognizerFailed, modelMissing]` |
| Gerät weg: Pillen-Alarm bei stiller Spur | Pille | `aSilentMicrophoneIsAnAlarmMarkAtItsPill` plus `withoutAReplacementDeviceTheTrackIsFilledAndTheReturnIsShown` (Ereignis `sourceDown`/`sourceRestored`) |

## Erwartet rot, wenn der Code so bleibt (jeweils ein Befund, kein Testfehler)

Nichts ist gelaufen; diese Tests sind aus dem Quelltext gelesen und sollten den Befund zeigen:

1. `twoStartsAtTheSameInstantAreOneRecording`: `Recorder.start` prüft `active[kind] == nil` am Anfang, trägt die Sitzung
   aber erst nach mehreren `await` ein (Actor-Wiedereintritt). Zwei Starts im selben Augenblick (prellender ⌘⌥U, beide lesen
   in `AppModel.shortcut` noch "läuft nicht") passieren beide die Prüfung: bei gleicher Sekunde scheitert der zweite mit
   "nicht gestartet", obwohl die Aufnahme läuft, bei verschiedener Sekunde überschreibt er `active[kind]` und die erste
   Sitzung läuft unbeaufsichtigt weiter. Naht für die Reparatur: Start-Marke vor dem ersten `await` setzen.
2. `everyWarningNamesItsNextStep`: `.problem("Call nicht gestartet")` hat keinen Schritt (`step == ("", nil)`).
3. `aDesktopThatIsDownIsNotReportedAsASilentMicrophone`: `AppModel.refresh` setzt `silent` auch, wenn nur der Desktop
   ausfällt, dann zeigt das Menü zusätzlich "Mikrofon ohne Pegel".

## Befunde ohne Test, weil die Anzeige oder die Naht fehlt ("Anzeige fehlt")

| Fall | Ist-Stand im Code | Was fehlt |
|---|---|---|
| Stift: Zeilenmodell je Datei | `DevicesPane` zeigt nur "n Dateien, zuletzt ..."; `Display.rowText` in der Support-Datei ist der Vertrag (kein Eintrag = wartet, copied = kopiert, transcribed = erkannt, done = abgelegt, failed = fehlgeschlagen, Erneut versuchen) | eine Dateiliste im Geräte-Bereich, Knopf "Erneut versuchen" = `scan()` |
| Stift: Kopieren gescheitert oder Datei beschädigt | kein Journal-Eintrag (`fail(nil, ...)`), nur der Gesamtstand `ImportProgress.failed`; `PillScene.ring(.failed)` ist `nil` (in `FinalReviewTests` festgeschrieben) | je Datei ein Eintrag `failed` mit Grund, sichtbare Marke |
| Platte voll beendet eine Aufnahme | `RecordingSession` stoppt sich selbst mit `diskFull`, `Recorder.active` merkt es nicht, das Menü zeigt weiter "Call läuft" | Meldung "Platte voll, Aufnahme gesichert" und Aufräumen in `Recorder` |
| Gerät weg mit Ersatz | `FlowIQApp` ignoriert `.deviceSwitched` (`case .deviceSwitched: break`) | Pillenmarke und Menüzeile "Call nimmt über ... auf" (B.5) |
| Nachlauf angehalten | jede Pause (Schlüssel, Kontingent, nicht erlaubt, drei leere Ergebnisse) zeigt "Schlüssel fehlt oder abgelehnt" | `AftercareState.paused` mit Grund, je ein Text mit eigenem Schritt |
| Rettung beim Start | `Recorder.rescue` ist still | Menüzeile "n Aufnahmen gerettet" (steht in den p3-Tests als Absicht) |
| Abgebrochenes Diktat beim Start wiederholen (R-022 "Wiederholen liefert Text") | kein Code startet es; Test prüft nur Audio, Journal und die Naht `recognizeFile` | Wiederholung offener Diktate (begin ohne recognized) beim Start |
| Stopp kommt, während `start` noch läuft | `Recorder.stop` findet noch nichts, die Aufnahme läuft danach weiter | Zustand "startet" im `Recorder` |
| Kurzbefehle in `AppModel.shortcut` | entscheidet an der `ui.running`-Momentaufnahme, nur über `Recorder` prüfbar | Funktion `shortcutDecision(running:)` ohne Fenster |
| `Recorder`-Tests und Sprachmodell | `Recorder` greift auf das Modell-Inventar des Macs (kein Mikrofon, kein Recht); fehlt es, läuft die Aufnahme mit "Live-Erkennung aus" | optional eine Naht `apple:` an `Recorder.init`, damit der Test hermetisch ist |

## Nur mit echter Hardware (nicht in dieser Matrix)

- Echtes AirPods-Trennen und -Verbinden, Telefonie-Modus, Abtastratenwechsel durch ein diktierendes Panotti (G-ECHT T1, T2).
- Mikrofon-Recht oder Bildschirmaufnahme-Recht in den Systemeinstellungen während einer Aufnahme entziehen; `SCStream`-Ende
  durch Sperrbildschirm; Deckel zu und Schlaf mitten in der Aufnahme.
- Echte volle Platte (`ENOSPC` im `TrackWriter`, `track_write_failed`): braucht ein Test-Abbild; die Tests hier prüfen nur
  die Schwellen über die Closure für den freien Platz.
- Echter Stift (DVT1600, ZEPHYR): USB-Abziehen mit Lesefehler `EIO` statt EOF, Schreibschutz-Schalter, Volume-Einhängen
  (`NSWorkspace.didMountNotification`); hier endet die Datei nur früh.
- Echte Tasten: Fn-Prellen an der echten Tastatur, Latenz des Event-Taps, Carbon-Kurzbefehle (`HotKeys`) und ihr Zusammenspiel
  mit dem Fn-Abgriff, drei Kombinationen in 50 ms in der laufenden App.
- Echter ElevenLabs-Ausfall (Netz, Kontingent, Sitzungsgrenze) gegen den echten Dienst; hier nur die Attrappe `FakePost`.
- Echter Apple-Erkennerfehler (Modell fehlt, Analyzer wirft); hier der Ersatz `Recognizer` mit demselben Verhalten.
- Harter Kill (`kill -9`) des laufenden Prozesses; hier der Zustand danach (abgerissene Spuren, hängender Nachlauf, hängende Kopie).
- Aussehen und Bewegung von Pille und Menüzeile (Pixel, Puls, Reduce Motion), VoiceOver-Ansagen.

## Laufzeit und Hinweise

- Langsam: `lessThanTwoHundredMegabytesEndsTheRecordingCleanlyWithTheAudioKept` (Tag `slow`, 10,2 s Echtzeit, weil die Platte nur
  alle 10 s Wanduhr geprüft wird), die zwei Desktop-Tests (ein Neustartversuch nach 1 s Echtzeit), die Neustart-Tests des Imports.
- Die Prüfung "Größe gegen Dauer" (`SizeVerdict`) hängt an der Wanduhr, die Töne an der virtuellen Zeit; die Tests verlangen daher
  nur `!= .lost`, die Rate hält P3.
- Neustart-Tests ohne echten Kill lassen den "toten" Prozess als hängenden Task zurück (Nachlauf-Dienst, Kopier-Tor, Erkennung
  mit 3.600 s Schlaf); das Test-Prozessende räumt sie ab.
