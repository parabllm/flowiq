<!-- TEST-FIX 16.11.: Beispielnamen neutralisiert, Prüflogik unverändert -->
# Acceptance tests for package P2 (text stage, `FlowIQText`)

**Purpose.** These tests were written from the description (`docs/ARCHITEKTUR.md` A.7 and Appendix G, `docs/LEXIKON-KONZEPT.md`, `docs/ABNAHME.md`), not from code. The text stage did not exist when they were written. The build agent builds `FlowIQText` so that these tests turn green unchanged.

**Rule: expected values are unchangeable.** The build agent may change only lines marked `// ASSUMPTION:`, all in `P2Support.swift` (initializers, field names, enum case names). Every expected value (`#expect(...)`, test inputs, thresholds such as 15 ms, 6 candidates, 15 %) stays. Changing a test needs a written reason plus an independent review. Test target (to be added to `Package.swift` by the build agent): path `abnahme-tests/p2`, depends on `FlowIQText`.

**Data.** Artificial only: NapIQ, VierbIQ, LaborIQ, FlowIQ, and invented names (Kelrana, Brimvolt, Zorbel, Deployr). No access to `local/korpus/`.

## Groups

| File | Group | Proves (ABNAHME) |
|---|---|---|
| `P2PassthroughTests` (5) | Passthrough: byte for byte, empty lexicon changes nothing | R-028 |
| `P2ProtectionTests` (7) | Protection: P1, P3 English stem plus German ending ("developen"), no-answer means protected, protected word only via active clicked variant | R-026, R-028 |
| `P2FamilyTests` (9) | Family IQ (R2), form variant (R1), Z1; unconfirmed entry changes nothing; Z2 off | R-029 (mechanics), R-011 |
| `P2SpokenFormTests` (5) | Spoken form (R3) only on strong match and confirmed target | R-011, R-028 |
| `P2AbbreviationTests` (4) | Uppercase runs up to 5 characters are never an R3 source | R-028 |
| `P2NoSmoothingTests` (5) | No grammar smoothing, no stutter removal | R-028 |
| `P2MassBrakeTests` (6) | Brake counts only R3 (more than 6 or above 15 % of tokens) | R-028 (L-6) |
| `P2PropertyTests` (4) | Idempotence over 600 generated inputs; determinism | R-028, R-035 (repeatability) |
| `P2TraceOracleTests` (7 + 5) | Trace (rule, source, target, reason, `stageTexts`); oracle (never uppercase, only unfrozen forms) | R-028, L-1 |
| `P2LearningTests` (13) | Probation (2 hits in 2 dictations, never on protected, first undo stills), candidate detector | R-031, R-030 (mechanics) |
| `P2PerformanceTests` (3) | p95 below 15 ms over 500 dictations; 300 words at most 15 ms | R-036 |

## Not proven here, proven in the corpus run (`flowiq-tool replay`, G-REPLAY)

- Damage rate: 0 harmful interventions in the withheld gold set, at most 0.3 % of dictations overall (R-026, R-028).
- Name hits on the gold set: at least 95 %, NapIQ, VierbIQ, LaborIQ, FlowIQ, ElevenLabs 100 % (R-029).
- Benefit and damage per rule kind, value of R3 in the three-way run (R-011).
- Full-corpus speed within 60 s and before/after runs for threshold changes (R-035).
- Hearing-variant benefit on the real history (R-031 corpus part), correction learning (R-032), five probe names end to end in the app (R-030, P7).
- Not covered: format of the recognizer's hesitation marks and control residue (`\letter`); the test inputs contain none.
