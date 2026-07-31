# Chained Pipeline Filter Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Change the target-topic filter design from "N single-stage `fn:` params ANDed" to "at most one RQL param + at most one `fn:` pipeline param per topic, with several `fn:` stages chained via `|` inside that one pipeline param" — across the main ditto repo (validator, javadoc, unit tests, docs) and the ditto-testing system tests.

**Architecture:** The user (design authority) decided on 2026-07-31 that the repeated-`fn:`-param form introduced by main-repo commit `ca17002257` is wrong: chaining `fn:` stages with `|` is the documented placeholder-pipeline idiom (https://eclipse.dev/ditto/basic-placeholders.html#function-expressions) and must be the way to AND several pipeline conditions. The changes are narrow: (1) `TargetTopicFilter.validatePipelineFilter` drops its top-level-pipe rejection — the pipeline grammar in `ImmutableExpressionResolver` already splits stages quote-aware (`PIPE_STAGE` consumes `'...'`/`"..."` whole) and caps pipelines at 10 function stages, so the resolver becomes the single validator; (2) `ConnectionValidator` gains an at-most-one-pipeline-param arity check mirroring the existing at-most-one-RQL check; (3) runtime AND-loops in `SignalFilter`/`OutboundMappingProcessorActor` stay untouched (they iterate a list that now holds ≤1 entry post-validation; keeping them is deliberate defensive behavior); (4) unit tests, system tests, and docs flip accordingly. Chained-AND semantics are guaranteed by `PipelineFunctionFilter.apply`: it acts `onResolved` (unresolved propagates) and passes the previous carrier value through on a match.

**Tech Stack:** Java 21, Maven, JUnit 4 + AssertJ (main repo unit tests), ditto-testing system-test harness (REST via `connectionsClient()`, live Ditto stack).

## Global Constraints

- **Two repos, one branch name each:** main repo worktree `/Users/sta1sf3/Develop/projects/bosch/ditto-ws/ditto_feature__target-topic-pipeline-filter`, testing repo worktree `/Users/sta1sf3/Develop/projects/Bosch/ditto-ws/ditto-testing_feature__target-topic-pipeline-filter`, both on branch `feature/target-topic-pipeline-filter`.
- **NEVER `git push`** — commit locally only (standing user rule).
- **Commit trailers** (both repos, every commit):
  `Signed-off-by: Aleksandar Stanchev <aleksandar.stanchev@bosch.com>` and
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- **Final design rules** (single source of truth for every task):
  - A topic's `filter` query param may be repeated; each value is classified by its trimmed `fn:` prefix (pipeline) vs anything else (RQL).
  - At most **one RQL** `filter` param per topic → violation: 400 `connectivity:connection.configuration.invalid` ("at most one RQL filter").
  - At most **one pipeline** (`fn:`) `filter` param per topic → violation: 400 `connectivity:connection.configuration.invalid` ("at most one pipeline filter"). **NEW RULE.**
  - Inside the single pipeline param, several `fn:` stages chain with `|` (AND; each stage runs only if the previous resolved). Max **10** `fn:` stages (enforced by the resolver's `MAX_COUNT_PIPELINE_FUNCTIONS`, surfaced as `connectivity:connection.configuration.invalid`). **Chaining is now LEGAL** — the "exactly one 'fn:' stage" rule is retired.
  - RQL + pipeline combine via the two params ANDed: `?filter=gt(attributes/counter,42)&filter=fn:filter(...)|fn:filter(...)`.
  - The legacy `<rql>|fn:...` single param (not starting with `fn:`) keeps failing whole in the RQL parser → 400 `rql.expression.invalid` (unchanged).
- **Main-repo maven:** run from the main repo root; scope with `-pl connectivity/service`. Expect `mvn` on PATH; if absent use `/opt/homebrew/Cellar/sdkman-cli/5.18.2/libexec/candidates/maven/3.9.3/bin/mvn`.
- **System tests need a rebuilt stack** — they run against a host-run Ditto (IntelliJ run configs) + dockerized brokers. Task 6 has an explicit USER CHECKPOINT for the rebuild; do not claim system-test success without run output (spec's own convention: executed evidence or it didn't happen).

---

### Task 1: Main repo — `TargetTopicFilter` allows chained stages

**Files:**
- Modify: `connectivity/service/src/main/java/org/eclipse/ditto/connectivity/service/messaging/TargetTopicFilter.java`
- Test: `connectivity/service/src/test/java/org/eclipse/ditto/connectivity/service/messaging/TargetTopicFilterTest.java`

**Interfaces:**
- Consumes: `ImmutableExpressionResolver` pipeline grammar (quote-aware stage split, ≤10 function stages) — unchanged.
- Produces: `TargetTopicFilter.validatePipelineFilter(String, DittoHeaders)` now ACCEPTS chained `fn:` expressions; still throws `ConnectionConfigurationInvalidException` for unknown functions/bad signatures/>10 stages/trailing pipe. `matchesPipelineFilter(...)` evaluates chained expressions with AND semantics (no code change — already delegates to the resolver). Task 2's validator and Task 3's tests rely on exactly this contract.

- [ ] **Step 1: Flip/add the unit tests (they must FAIL against current code)**

In `TargetTopicFilterTest.java`:

1a. REPLACE the whole test `validatePipelineFilterRejectsTwoStageParam` (lines ~248-254) with:

```java
    @Test
    public void validatePipelineFilterAcceptsChainedStages() {
        assertThatNoException().isThrownBy(() ->
                TargetTopicFilter.validatePipelineFilter(
                        "fn:filter(header:a,'exists')|fn:filter(header:b,'exists')", DittoHeaders.empty()));
    }

    @Test
    public void validatePipelineFilterRejectsChainedParamWithUnknownFunctionStage() {
        assertThatExceptionOfType(ConnectionConfigurationInvalidException.class).isThrownBy(() ->
                TargetTopicFilter.validatePipelineFilter(
                        "fn:filter(header:a,'exists')|fn:unknownfn('x')", DittoHeaders.empty()));
    }

    @Test
    public void validatePipelineFilterAcceptsTenChainedStagesButRejectsEleven() {
        // the resolver's pipeline grammar caps a pipeline at 10 fn: stages (the internal fn:default seed does
        // not eat into the user's budget: seed + 10 user stages is exactly the grammar's 11-element maximum)
        final String tenStages = String.join("|", Collections.nCopies(10, "fn:filter(header:a,'exists')"));
        assertThatNoException().isThrownBy(() ->
                TargetTopicFilter.validatePipelineFilter(tenStages, DittoHeaders.empty()));

        final String elevenStages = String.join("|", Collections.nCopies(11, "fn:filter(header:a,'exists')"));
        assertThatExceptionOfType(ConnectionConfigurationInvalidException.class).isThrownBy(() ->
                TargetTopicFilter.validatePipelineFilter(elevenStages, DittoHeaders.empty()));
    }

    @Test
    public void validatePipelineFilterAcceptsQuotedPipeInsideChainedStages() {
        // the resolver's stage split is quote-aware: the '|' inside 'a|b' must not be taken for a stage separator
        assertThatNoException().isThrownBy(() ->
                TargetTopicFilter.validatePipelineFilter(
                        "fn:filter(header:a,'eq','a|b')|fn:filter(header:b,'exists')", DittoHeaders.empty()));
    }
```

(`Collections` is already imported at line 21. Update the section comment above this block from `// ===== validatePipelineFilter(): exactly one stage per filter parameter =====` to `// ===== validatePipelineFilter(): chained stages, pipeline grammar limits =====`.)

1b. KEEP `validatePipelineFilterRejectsTrailingPipe` as-is (a trailing `|` no longer trips a custom scan, but the resolver's `PIPE_PATTERN` refuses an empty trailing stage → `UnresolvedPlaceholderException` → wrapped into the same exception type). Add this comment inside, above the assertion:

```java
        // rejected by the resolver's pipeline grammar (empty trailing stage), no custom scan involved
```

1c. In `validatePipelineFilterTrailingBackslashDoesNotThrowUnexpectedly`, replace the stale comment (it references the deleted scan):

```java
        // a trailing backslash must never escape the documented exception contract; the resolver validation may
        // still reject the expression, but only ever with the documented exception type
```

1d. ADD chained-evaluation tests after `matchesPipelineFilterAbsentHeaderTwoParamExistsDrops` (~line 217):

```java
    // ===== matchesPipelineFilter(): chained stages (AND semantics) =====

    @Test
    public void matchesPipelineFilterChainedStagesBothMatchPublishes() {
        final Signal<?> signal = thingModifiedWithHeaders(Map.of(
                "ditto-originator", "some:subject",
                "ditto-origin", "some-origin"));

        assertThat(TargetTopicFilter.matchesPipelineFilter(
                "fn:filter(header:ditto-originator,'eq','some:subject')" +
                        "|fn:filter(header:ditto-origin,'eq','some-origin')", signal, CONNECTION_ID)).isTrue();
    }

    @Test
    public void matchesPipelineFilterChainedStagesFirstNonMatchDrops() {
        final Signal<?> signal = thingModifiedWithHeaders(Map.of(
                "ditto-originator", "other:subject",
                "ditto-origin", "some-origin"));

        assertThat(TargetTopicFilter.matchesPipelineFilter(
                "fn:filter(header:ditto-originator,'eq','some:subject')" +
                        "|fn:filter(header:ditto-origin,'eq','some-origin')", signal, CONNECTION_ID)).isFalse();
    }

    @Test
    public void matchesPipelineFilterChainedStagesSecondNonMatchDrops() {
        final Signal<?> signal = thingModifiedWithHeaders(Map.of(
                "ditto-originator", "some:subject",
                "ditto-origin", "other-origin"));

        assertThat(TargetTopicFilter.matchesPipelineFilter(
                "fn:filter(header:ditto-originator,'eq','some:subject')" +
                        "|fn:filter(header:ditto-origin,'eq','some-origin')", signal, CONNECTION_ID)).isFalse();
    }
```

- [ ] **Step 2: Run the test class — expect the flipped/new validation tests to FAIL**

Run (main repo root):
```bash
mvn -pl connectivity/service test -Dtest=TargetTopicFilterTest -q
```
Expected: FAIL — `validatePipelineFilterAcceptsChainedStages`, `validatePipelineFilterAcceptsTenChainedStagesButRejectsEleven` (10-stage half), `validatePipelineFilterAcceptsQuotedPipeInsideChainedStages` throw `ConnectionConfigurationInvalidException` ("exactly one 'fn:' stage") from the still-present pipe scan. The three chained `matchesPipelineFilter` tests PASS already (runtime never had the scan) — that is expected; the failing validation tests are the ones driving the change.

- [ ] **Step 3: Remove the top-level-pipe rejection from `TargetTopicFilter`**

In `TargetTopicFilter.java`:

3a. DELETE the entire `containsTopLevelPipe` method (lines ~115-137) including its javadoc.

3b. In `validatePipelineFilter`, DELETE the leading rejection block:

```java
        if (containsTopLevelPipe(pipelineExpression)) {
            throw ConnectionConfigurationInvalidException
                    .newBuilder("The target topic pipeline filter expression '" + pipelineExpression +
                            "' is invalid: a 'filter' parameter must consist of exactly one 'fn:' stage.")
                    .description("To combine several filter conditions with AND, use one 'filter' query parameter " +
                            "per condition instead, e.g. '?filter=fn:filter(...)&filter=fn:filter(...)'.")
                    .dittoHeaders(dittoHeaders)
                    .build();
        }
```

so the method body is only the `try { VALIDATION_RESOLVER...` block.

3c. Replace the `validatePipelineFilter` javadoc first paragraph with:

```java
    /**
     * Validates a pipeline expression at connection-creation/update time, i.e. strictly: any placeholder/pipeline
     * function error is rejected. Several {@code fn:} stages may be chained with {@code |} inside the one pipeline
     * filter parameter; the resolver's pipeline grammar enforces the structure (quote-aware stage splitting, every
     * stage a function invocation, at most 10 {@code fn:} stages).
```

(keep the `@param`/`@throws` lines, but change the `@throws` reason list to `e.g. because it references an unknown placeholder function, has an invalid function signature, exceeds the maximum number of pipeline stages, or references an unresolvable placeholder.`)

3d. Replace the class javadoc sentence starting `Each {@code filter} parameter value is either a placeholder pipeline expression consisting of exactly one function stage ...` up to `...via {@link #validatePipelineFilter(String, DittoHeaders)}.` with:

```java
 * A target topic may carry up to two {@code filter} query parameters which are combined with AND semantics: at
 * most one RQL expression (any value not starting with {@code fn:}, unchanged existing behavior) and at most one
 * placeholder pipeline expression starting with {@code fn:}
 * (e.g. {@code fn:filter(header:ditto-originator,'ne','x')}). Several {@code fn:} stages may be chained with
 * {@code |} inside the pipeline parameter — a stage only runs if the previous one resolved, so chaining is AND as
 * well. Both at-most-one arity rules are enforced at connection creation/update time by
 * {@code ConnectionValidator}; the pipeline expression itself is validated via
 * {@link #validatePipelineFilter(String, DittoHeaders)}.
```

(adjust the opening line `A target topic may carry multiple {@code filter} query parameters ...` accordingly — it is replaced by the text above).

3e. In the `partition` javadoc, replace `after successful connection validation the RQL partition holds at most one entry, but pre-validation input may violate that - the at-most-one-RQL rule is enforced by {@code ConnectionValidator}` with `after successful connection validation each partition holds at most one entry, but pre-validation input may violate that - both at-most-one rules are enforced by {@code ConnectionValidator}`. Same adjustment in the `PartitionedFilters#getRqlExpressions()` javadoc (`at most one entry after successful connection validation` stays true — no change needed there) and ADD the same phrase to `getPipelineExpressions()` javadoc: `@return the pipeline expressions (each without the mandatory seed) among the topic's filters - at most one entry after successful connection validation, but possibly more for not (yet) validated input.`

- [ ] **Step 4: Run the test class — expect PASS**

```bash
mvn -pl connectivity/service test -Dtest=TargetTopicFilterTest -q
```
Expected: PASS, all tests green.

- [ ] **Step 5: Commit (main repo)**

```bash
cd /Users/sta1sf3/Develop/projects/bosch/ditto-ws/ditto_feature__target-topic-pipeline-filter
git add connectivity/service/src/main/java/org/eclipse/ditto/connectivity/service/messaging/TargetTopicFilter.java \
        connectivity/service/src/test/java/org/eclipse/ditto/connectivity/service/messaging/TargetTopicFilterTest.java
git commit -m "refactor(connectivity): allow chaining fn: stages in a target topic pipeline filter param

Chaining fn: stages with '|' is the documented placeholder-pipeline idiom
and is legal again for target topic pipeline filters: the top-level-pipe
scan in TargetTopicFilter.validatePipelineFilter is removed and the
resolver's pipeline grammar becomes the single structural validator
(quote-aware stage split, every stage an fn: invocation, at most 10
stages). Chained stages evaluate with AND semantics: a stage only runs
if the previous one resolved.

Part 1/2 of the chained-pipeline redesign; part 2 caps a topic's filter
params at one RQL + one fn: param in ConnectionValidator.

Signed-off-by: Aleksandar Stanchev <aleksandar.stanchev@bosch.com>
Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Main repo — `ConnectionValidator` caps pipeline params at one per topic

**Files:**
- Modify: `connectivity/service/src/main/java/org/eclipse/ditto/connectivity/service/messaging/validation/ConnectionValidator.java` (~lines 333-355)
- Test: `connectivity/service/src/test/java/org/eclipse/ditto/connectivity/service/messaging/validation/ConnectionValidatorTest.java` (~lines 490-560)

**Interfaces:**
- Consumes: `TargetTopicFilter.partition(List)` / `PartitionedFilters.getPipelineExpressions()` (Task 1, unchanged signatures) and Task 1's chained-accepting `validatePipelineFilter`.
- Produces: connection create/modify rejects a topic with 2+ `fn:` params with `ConnectionConfigurationInvalidException`, message containing `at most one pipeline filter`. Task 5's system test asserts the resulting 400 + error code.

- [ ] **Step 1: Flip the two arity unit tests (must FAIL against current code)**

In `ConnectionValidatorTest.java`:

1a. REPLACE test `acceptConnectionWithMultiplePipelineTargetFilterParams` (~lines 490-507) with:

```java
    @Test
    public void rejectConnectionWithTwoPipelineTargetFilterParams() {
        // at most one of a topic's filter params may be a pipeline expression - several pipeline conditions
        // belong into ONE fn: param, chained with '|'
        final List<Target> targetWithInvalidFilters = singletonList(
                ConnectivityModelFactory.newTargetBuilder(TestConstants.Targets.TWIN_TARGET)
                        .topics(ConnectivityModelFactory.newFilteredTopicBuilder(Topic.TWIN_EVENTS)
                                .withFilters(List.of(
                                        "fn:filter(header:ditto-originator,'ne','some:subject')",
                                        "fn:filter(header:ditto-origin,'ne','some-connection-id')"))
                                .build())
                        .build());
        final Connection connection = createConnection(CONNECTION_ID)
                .toBuilder()
                .setTargets(targetWithInvalidFilters)
                .build();
        final ConnectionValidator underTest = getConnectionValidator();
        assertThatExceptionOfType(ConnectionConfigurationInvalidException.class)
                .isThrownBy(() -> underTest.validate(connection, DittoHeaders.empty(), actorSystem))
                .withMessageContaining("at most one pipeline filter");
    }
```

1b. REPLACE test `rejectConnectionWithMultiStagePipelineTargetFilterParam` (~lines 530-547) with:

```java
    @Test
    public void acceptConnectionWithChainedPipelineTargetFilterParam() {
        // several fn: stages chained with '|' inside the ONE pipeline filter param are the intended way to
        // AND several pipeline conditions
        final List<Target> targetWithValidFilter = singletonList(
                ConnectivityModelFactory.newTargetBuilder(TestConstants.Targets.TWIN_TARGET)
                        .topics(ConnectivityModelFactory.newFilteredTopicBuilder(Topic.TWIN_EVENTS)
                                .withFilter("fn:filter(header:a,'exists')|fn:filter(header:b,'exists')")
                                .build())
                        .build());
        final Connection connection = createConnection(CONNECTION_ID)
                .toBuilder()
                .setTargets(targetWithValidFilter)
                .build();
        final ConnectionValidator underTest = getConnectionValidator();
        underTest.validate(connection, DittoHeaders.empty(), actorSystem);
    }
```

- [ ] **Step 2: Run — expect exactly these two to FAIL**

```bash
mvn -pl connectivity/service test -Dtest=ConnectionValidatorTest -q
```
Expected: `rejectConnectionWithTwoPipelineTargetFilterParams` fails (no exception thrown — current code accepts N pipeline params); `acceptConnectionWithChainedPipelineTargetFilterParam` passes already (Task 1 removed the scan). If `acceptConnectionWithChainedPipelineTargetFilterParam` FAILS, Task 1 was not completed — stop and fix Task 1 first.

- [ ] **Step 3: Add the arity check in `ConnectionValidator`**

In `ConnectionValidator.java`, directly AFTER the existing at-most-one-RQL `if` block (ends `.build(); }` ~line 349) and BEFORE `partitionedFilters.getPipelineExpressions().forEach(...)`, insert:

```java
                    if (partitionedFilters.getPipelineExpressions().size() > 1) {
                        throw ConnectionConfigurationInvalidException
                                .newBuilder("The topic '" + topic + "' of the target with address '" +
                                        target.getAddress() + "' declares " +
                                        partitionedFilters.getPipelineExpressions().size() +
                                        " pipeline 'filter' parameters - at most one pipeline filter is allowed " +
                                        "per topic.")
                                .description("Combine several pipeline conditions by chaining 'fn:' stages with " +
                                        "'|' inside the single pipeline 'filter' parameter instead, e.g. " +
                                        "'?filter=fn:filter(...)|fn:filter(...)'.")
                                .dittoHeaders(dittoHeaders)
                                .build();
                    }
```

And update the RQL check's description string from
`"Combine several RQL conditions into a single RQL expression using 'and(...)'. Additional 'filter' parameters may only hold placeholder pipeline expressions starting with 'fn:'."`
to
`"Combine several RQL conditions into a single RQL expression using 'and(...)'. Besides the RQL filter, a topic may only carry one more 'filter' parameter holding a placeholder pipeline expression starting with 'fn:'."`

- [ ] **Step 4: Run — expect PASS**

```bash
mvn -pl connectivity/service test -Dtest=ConnectionValidatorTest -q
```
Expected: PASS (whole class).

- [ ] **Step 5: Commit (main repo)**

```bash
git add connectivity/service/src/main/java/org/eclipse/ditto/connectivity/service/messaging/validation/ConnectionValidator.java \
        connectivity/service/src/test/java/org/eclipse/ditto/connectivity/service/messaging/validation/ConnectionValidatorTest.java
git commit -m "refactor(connectivity): at most one pipeline filter param per target topic

Part 2/2 of the chained-pipeline redesign: a topic now carries at most
TWO filter query params - one RQL expression and one fn: pipeline
expression. A second fn: param is rejected at connection create/modify
time with connectivity:connection.configuration.invalid, mirroring the
existing at-most-one-RQL arity rule; several pipeline conditions belong
into the single fn: param chained with '|'.

Signed-off-by: Aleksandar Stanchev <aleksandar.stanchev@bosch.com>
Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Main repo — runtime tests use the chained form; `SignalFilter` javadoc

**Files:**
- Modify: `connectivity/service/src/main/java/org/eclipse/ditto/connectivity/service/messaging/persistence/SignalFilter.java` (javadoc only, ~lines 117-119)
- Test: `connectivity/service/src/test/java/org/eclipse/ditto/connectivity/service/messaging/persistence/SignalFilterWithFilterTest.java` (~lines 722-870)
- Test: `connectivity/service/src/test/java/org/eclipse/ditto/connectivity/service/messaging/OutboundMappingProcessorActorTest.java` (~lines 923-985)

**Interfaces:**
- Consumes: `TargetTopicFilter.matchesPipelineFilter` chained-AND evaluation (Task 1). Runtime loops in `SignalFilter.filter(...)` / `OutboundMappingProcessorActor` stay list-based — that is deliberate defensive behavior for never-validated model-built input; do NOT simplify them to a single Optional.
- Produces: runtime unit coverage of the chained form (the design's intended usage) at both evaluation sites, plus one retained multi-param test locking the defensive loop.

- [ ] **Step 1: Convert the AND-semantics tests to the chained form**

1a. `SignalFilterWithFilterTest.java` — section comment `// ===== multiple pipeline filter params on one topic (AND semantics) =====` becomes `// ===== chained pipeline stages in one filter param (AND semantics) =====`.

1b. Test `applySignalFilterWithTwoPipelineFilterParamsAndSemantics` → rename to `applySignalFilterWithChainedPipelineStagesAndSemantics` and replace its topic builder call:

```java
                .topics(ConnectivityModelFactory.newFilteredTopicBuilder(TWIN_EVENTS)
                        .withFilters(List.of(
                                "fn:filter(header:ditto-originator,'ne','excluded:subject')" +
                                        "|fn:filter(header:ditto-origin,'ne','excluded-connection')"))
                        .build())
```

Keep all three scenario blocks; update their comments from `first/second pipeline param does not match` to `first/second chained stage does not match` (and `both pipeline params match` → `both chained stages match`).

1c. Test `applySignalFilterWithRqlAndTwoPipelineFilterParams` → rename to `applySignalFilterWithRqlAndChainedPipelineFilterParam`, topic builder becomes:

```java
                .topics(ConnectivityModelFactory.newFilteredTopicBuilder(TWIN_EVENTS)
                        .withFilters(List.of(
                                "eq(attributes/test,42)",
                                "fn:filter(header:ditto-originator,'ne','excluded:subject')" +
                                        "|fn:filter(header:ditto-origin,'ne','excluded-connection')"))
                        .build())
```

Same comment adjustments (`first pipeline param` → `first chained stage`, etc.). Local variable names `firstPipelineNonMatch`/`secondPipelineNonMatch` may stay.

1d. Test `applySignalFilterWithFailingSecondPipelineFilterParamRecordsFailureForThatParam`: KEEP the two-param `withFilters(List.of(matchingFilter, failingFilter))` shape, and replace its leading comment with:

```java
        // DEFENSIVE lock: validation now caps a topic at one pipeline filter param, but the runtime AND-loop
        // must keep handling multi-param lists that never passed validation (model-built or pre-rule persisted
        // connections). The first param evaluates fine (and matches), the second throws at evaluation time -
        // the failure entry must name the FAILING param, not the first one.
```

1e. `OutboundMappingProcessorActorTest.java` — `multiplePipelineFilterParamsWithExtraFieldsAllMatchPublishesEnriched` → rename to `chainedPipelineStagesWithExtraFieldsAllMatchPublishesEnriched`, filters become:

```java
                    .withFilters(List.of("fn:filter(header:ditto-originator,'eq','x')" +
                            "|fn:filter(header:ditto-originator,'ne','y')"))
```

Comment: `// A single topic with one pipeline filter param chaining TWO fn: stages (AND semantics) and extraFields: both stages match, so the signal is published with the topic's extra fields after the post-enrichment re-evaluation.`

1f. `multiplePipelineFilterParamsSecondNonMatchDropsTarget` → rename to `chainedPipelineStagesSecondStageNonMatchDropsTarget`, filters become:

```java
                    .withFilters(List.of("fn:filter(header:ditto-originator,'eq','x')" +
                            "|fn:filter(header:ditto-originator,'ne','x')"))
```

Comment: `// Same topic shape as above, but the SECOND chained stage does not match ("ne 'x'" with originator "x") - AND semantics must drop the whole target even though the first stage matches.`

- [ ] **Step 2: Run both test classes — expect PASS**

```bash
mvn -pl connectivity/service test -Dtest='SignalFilterWithFilterTest,OutboundMappingProcessorActorTest' -q
```
Expected: PASS. (These conversions exercise code paths already accepting chained expressions after Task 1 — a failure here means chained evaluation is broken; debug with superpowers:systematic-debugging before proceeding.)

- [ ] **Step 3: Update `SignalFilter.filter(...)` javadoc**

Replace (lines ~117-119):

```java
     * A target topic may carry multiple {@code filter} parameters, combined with AND semantics: at most one RQL
     * expression (unchanged, existing behavior) plus any number of placeholder pipeline expressions
     * ({@code fn:...}, see {@link org.eclipse.ditto.connectivity.service.messaging.TargetTopicFilter}). The
```

with:

```java
     * A target topic may carry up to two {@code filter} parameters, combined with AND semantics: at most one RQL
     * expression (unchanged, existing behavior) plus at most one placeholder pipeline expression ({@code fn:...},
     * possibly chaining several stages with {@code |} - see
     * {@link org.eclipse.ditto.connectivity.service.messaging.TargetTopicFilter}); the loop below defensively
     * AND-evaluates every pipeline entry it finds, even for never-validated topics carrying more. The
```

Also check `SignalFilter.java` line ~468 and `OutboundMappingProcessorActor.java` lines ~857-861 comments — they describe evaluation order/guarding, not arity, and need no change (verify by reading; change only if they claim "any number of pipeline params").

- [ ] **Step 4: Compile + run once more**

```bash
mvn -pl connectivity/service test -Dtest='SignalFilterWithFilterTest,OutboundMappingProcessorActorTest,TargetTopicFilterTest,ConnectionValidatorTest' -q
```
Expected: PASS.

- [ ] **Step 5: Commit (main repo)**

```bash
git add connectivity/service/src/main/java/org/eclipse/ditto/connectivity/service/messaging/persistence/SignalFilter.java \
        connectivity/service/src/test/java/org/eclipse/ditto/connectivity/service/messaging/persistence/SignalFilterWithFilterTest.java \
        connectivity/service/src/test/java/org/eclipse/ditto/connectivity/service/messaging/OutboundMappingProcessorActorTest.java
git commit -m "test(connectivity): runtime pipeline filter tests use chained fn: stages

The AND-semantics runtime tests now exercise the intended chained form
(one fn: param, stages joined with '|') at both evaluation sites
(SignalFilter pre-enrichment gate, OutboundMappingProcessorActor
post-enrichment re-evaluation). One deliberately multi-param test stays
as a defensive lock: the runtime AND-loop keeps handling never-validated
multi-param lists, with per-param failure attribution.

Signed-off-by: Aleksandar Stanchev <aleksandar.stanchev@bosch.com>
Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Main repo — documentation + full-module verification

**Files:**
- Modify: `documentation/src/main/resources/pages/ditto/basic-connections.md` (~lines 292-296, 354-375, 396-406)
- Modify: `documentation/src/main/resources/pages/ditto/basic-placeholders.md` (~lines 328-340)
- Modify: `documentation/src/main/resources/pages/ditto/basic-changenotifications.md` (~lines 52-58)
- Modify: `documentation/src/main/resources/jsonschema/connection.json` (~line 659)

**Interfaces:**
- Consumes: final design rules from Global Constraints (verbatim).
- Produces: docs that state: at most one RQL + at most one `fn:` param, chaining with `|` (AND, max 10 stages) inside the `fn:` param, RQL+pipeline combined via two params.

- [ ] **Step 1: `basic-connections.md`**

1a. Intro paragraph (~line 295): replace

> The `filter` parameter may be given **multiple times** on one topic; all given filters must match for a signal to be published (**AND** semantics, see [filtering with placeholder functions](#filtering-with-placeholder-functions) below).

with

> The `filter` parameter may be given **twice** on one topic — at most one RQL expression and at most one placeholder pipeline expression (`fn:...`); all given filters must match for a signal to be published (**AND** semantics, see [filtering with placeholder functions](#filtering-with-placeholder-functions) below).

1b. The paragraph beginning `Each `filter` query parameter holds exactly **one** filter: either one RQL expression or one `fn:` function invocation.` (~line 357) and its `filter=fn:...&filter=fn:...` example: replace the paragraph + example with

```text
A `filter` query parameter whose (trimmed) value starts with `fn:` is a pipeline filter; anything
else is treated as RQL. Several `fn:` stages can be chained with `|` inside the pipeline filter.
Each stage only runs if the previous one resolved (matched), so chaining is **AND**: every stage
must match for the pipeline to resolve, for example:
```
```text
filter=fn:filter(header:ditto-originator,'ne','some:subject')|fn:filter(header:ditto-origin,'ne','some-connection-id')
```

1c. KEEP the following `An RQL filter and pipeline filters can be freely combined ...` paragraph and its `filter=gt(attributes/counter,42)&filter=fn:filter(...)` example, but singularize: `An RQL filter and a pipeline filter can be combined as two `filter` parameters, again with **AND** semantics -- the RQL expression and the pipeline must both match:`

1d. Replace the closing arity paragraph (`At most **one** of a topic's `filter` parameters may be an RQL expression -- ... Any number of additional `fn:` filter parameters is allowed.`) with:

> At most **one** of a topic's `filter` parameters may be an RQL expression -- combine several RQL conditions into a single expression with `and(...)` instead. Likewise at most **one** may be a pipeline expression -- combine several pipeline conditions by chaining `fn:` stages with `|` inside it.

1e. Restrictions bullets (~line 398): replace the two bullets

> * Each `fn:` filter parameter must consist of exactly **one** function stage -- chaining several stages with `|` inside one parameter is rejected at connection creation/update time. Use one `filter` parameter per condition instead (`filter=fn:...&filter=fn:...`).
> * At most **one** of a topic's `filter` parameters may be an RQL expression; a second one is rejected at connection creation/update time. Combine RQL conditions with `and(...)` instead.

with

> * As with any placeholder pipeline, every stage after the first must itself be an `fn:` function call -- a bare placeholder cannot appear mid-pipeline.
> * A pipeline filter may contain at most **10** `fn:` stages; exceeding the limit is rejected at connection creation/update time.
> * A topic accepts at most **one** RQL `filter` parameter and at most **one** pipeline `filter` parameter; a second one of either kind is rejected at connection creation/update time. Combine RQL conditions with `and(...)` and pipeline conditions by chaining stages with `|`.

- [ ] **Step 2: `basic-placeholders.md`** (~line 330): replace

> a placeholder function invocation (most commonly [`fn:filter()`](#function-library)) may be used as a `filter` query parameter, alongside an optional [RQL expression](basic-rql.html) `filter` parameter and further `fn:` `filter` parameters (each parameter holds exactly one function invocation; all of a topic's filters are combined with AND).

with

> a placeholder function pipeline (most commonly [`fn:filter()`](#function-library), several stages chainable with `|`) may be used as a `filter` query parameter, alongside an optional [RQL expression](basic-rql.html) `filter` parameter (at most one of each; all of a topic's filters are combined with AND).

Also revert the two sentences that were de-pipelined: `such an expression is bare and placeholders must not be surrounded by curly braces` → `such a pipeline is a bare expression and placeholders must not be surrounded by curly braces`; `The expression is evaluated per outbound signal` → `The pipeline is evaluated per outbound signal`.

- [ ] **Step 3: `basic-changenotifications.md`** (~line 55): replace

> [Connections](basic-connections.html) additionally accept placeholder function filters (`fn:...`) in additional `filter` parameters alongside (or instead of) an RQL expression

with

> [Connections](basic-connections.html) additionally accept a placeholder function pipeline (`fn:...`) in an additional `filter` parameter alongside (or instead of) an RQL expression

- [ ] **Step 4: `connection.json`** (~line 659): in the topics item description, replace the tail

> The `filter` parameter may be repeated: each occurrence holds either one RQL expression (at most one per topic) or one placeholder pipeline expression starting with `fn:`; all given filters must match (AND)

with

> The `filter` parameter may be repeated: at most one RQL expression and at most one placeholder pipeline expression starting with `fn:` (several `fn:` stages chainable with `|`); all given filters must match (AND)

(Keep both examples — the two-param example `?filter=gt(attributes/counter,42)&filter=fn:filter(...)` is still valid under the new rules.)

- [ ] **Step 5: Repo-wide stale-rule scan**

```bash
cd /Users/sta1sf3/Develop/projects/bosch/ditto-ws/ditto_feature__target-topic-pipeline-filter
grep -rn "exactly one 'fn:' stage\|exactly one .fn:. stage\|one 'filter' query parameter per condition\|use one filter param per condition" --include='*.java' --include='*.md' --include='*.json' . | grep -v '/target/'
```
Expected: NO hits in `main/` sources or docs (hits inside `docs/superpowers/` history files are fine — leave those; they are historical records).

- [ ] **Step 6: Full connectivity/service test run**

```bash
mvn -pl connectivity/service test -q
```
Expected: PASS (full module — catches any test not touched above that still assumes the old rules).

- [ ] **Step 7: Commit (main repo)**

```bash
git add documentation/src/main/resources/pages/ditto/basic-connections.md \
        documentation/src/main/resources/pages/ditto/basic-placeholders.md \
        documentation/src/main/resources/pages/ditto/basic-changenotifications.md \
        documentation/src/main/resources/jsonschema/connection.json
git commit -m "docs(connectivity): document chained fn: stages and one-RQL-plus-one-fn: filter params

Signed-off-by: Aleksandar Stanchev <aleksandar.stanchev@bosch.com>
Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Testing repo — system tests adopt the chained design

**Files:**
- Modify: `system/src/test/java/org/eclipse/ditto/testing/system/connectivity/rest/RestConnectionsIT.java` (~lines 416-502)
- Modify: `system/src/test/java/org/eclipse/ditto/testing/system/connectivity/AbstractConnectivityITestCases.java` (lines 1121, 1145 comments)
- Modify: `docs/superpowers/specs/2026-07-17-target-topic-pipeline-filter-system-tests.md` (banner + status)
- NO change: `ConnectivityFactory.java` — `setupSingleConnectionWithCombinedRqlAndPipelineFilter` builds `?filter=gt(attributes/counter,42)&filter=fn:filter(...)` = one RQL + one `fn:` param, valid under the new rules (verify by reading, do not edit).

**Interfaces:**
- Consumes: server behavior from Tasks 1-2 (two `fn:` params → 400 `connectivity:connection.configuration.invalid`; chained param → 201 and round-trips verbatim).
- Produces: compile-clean system tests; execution happens in Task 6.

- [ ] **Step 1: Flip the multi-stage negative test in `RestConnectionsIT`**

REPLACE `createConnectionWithMultiStagePipelineTargetTopicFilterParamFails` (~lines 416-429) with:

```java
    @Test
    public void createConnectionWithTwoPipelineTargetTopicFilterParamsFails() {
        // WHEN a topic declares two fn: filter params (at most one is allowed - several pipeline conditions
        // must be chained with '|' inside the single fn: param instead)
        final JsonObject connection = connectionWithTargetTopics(
                "_/_/things/twin/events?filter=fn:filter(header:x,'exists')&filter=fn:filter(header:y,'exists')");

        connectionsClient()
                .postConnection(connection)
                .withDevopsAuth()
                .expectingHttpStatus(HttpStatus.BAD_REQUEST)
                .expectingErrorCode("connectivity:connection.configuration.invalid")
                .fire();
    }
```

- [ ] **Step 2: Extend valid-filters test I with the chained form + anchor its assertions**

In `createConnectionWithValidPipelineTargetTopicFilters` (~lines 463-502):

2a. Update the WHEN comment to `// WHEN a connection defines pure-pipeline, chained-pipeline and RQL-plus-pipeline target topic filter params - including an unknown rqlFunction NAME ('nope'), which is accepted at creation time (documented behavior; it simply never matches at runtime)`.

2b. Add a 4th topic (chained; twin/events may appear twice — each topic entry carries its own filters):

```java
        final JsonObject connection = connectionWithTargetTopics(
                "_/_/things/twin/events?filter=fn:filter(header:ditto-originator,'ne','integration:some:excluded')",
                "_/_/things/twin/events?filter=fn:filter(header:ditto-origin,'ne','chained-excluded-connection')" +
                        "|fn:filter(header:ditto-originator,'exists')",
                "_/_/things/live/messages?filter=gt(attributes/counter,42)" +
                        "&filter=fn:filter(header:ditto-originator,'ne','integration:some:excluded')",
                "_/_/things/live/events?filter=fn:filter(header:ditto-originator,'nope','integration:some:excluded')");
```

2c. Replace the round-trip assertion block body with (anchored per topic — review finding: the old first `contains` was subsumed by the combined topic's substring):

```java
                    .expectingBody(satisfies(jsonString -> {
                        assertThat(String.valueOf(jsonString))
                                .contains("twin/events?filter=fn:filter(header:ditto-originator,'ne'," +
                                        "'integration:some:excluded')");
                        assertThat(String.valueOf(jsonString))
                                .contains("fn:filter(header:ditto-origin,'ne','chained-excluded-connection')" +
                                        "|fn:filter(header:ditto-originator,'exists')");
                        assertThat(String.valueOf(jsonString))
                                .contains("gt(attributes/counter,42)&filter=fn:filter(header:ditto-originator,'ne'");
                        assertThat(String.valueOf(jsonString))
                                .contains("fn:filter(header:ditto-originator,'nope'");
                    }))
```

CAUTION on 2c: the serialized topic string is produced by `ImmutableFilteredTopic.toString()` from the *parsed* form — if the run in Task 6 shows the persisted string differs (e.g. URL-encoding of `|`), adjust the expected substring to what the server actually (correctly) returns, and note it in the spec.

- [ ] **Step 3: Fix the two stale "RQL head" comments in `AbstractConnectivityITestCases`**

Line 1121: `// (counter=10 <= 42, other originator connection2) -> suppressed by the RQL head` → `// (counter=10 <= 42, other originator connection2) -> suppressed by the RQL filter param`
Line 1145: `.describedAs("events failing the RQL head or the pipeline stage must be suppressed")` → `.describedAs("events failing the RQL filter param or the pipeline filter param must be suppressed")`
(Scenario-B's syntax comment at ~1081-1082 already shows the two-param form and stays.)

- [ ] **Step 4: Update the spec banner**

In `docs/superpowers/specs/2026-07-17-target-topic-pipeline-filter-system-tests.md`, replace the `> **SYNTAX CHANGE 2026-07-31:** ...` blockquote with:

```markdown
> **SYNTAX CHANGE 2026-07-31 (rev 2, chained-pipeline redesign):** a target topic carries at most TWO
> `filter` query params — at most one RQL expression and at most one `fn:` pipeline expression, ANDed:
> `?filter=gt(attributes/counter,42)&filter=fn:filter(...)`. Several pipeline conditions are chained with
> `|` INSIDE the single `fn:` param (AND, max 10 stages): `?filter=fn:filter(...)|fn:filter(...)`. A second
> param of either kind → 400 `connectivity:connection.configuration.invalid`; the legacy `rql|fn:` single
> param (not starting with `fn:`) → 400 `rql.expression.invalid`. Rev 1 of this banner (repeated single-stage
> `fn:` params, "exactly one fn: stage per param") was implemented in ditto `ca17002257` + here in `6c94457`
> and then REVERSED by the user's design call — chaining is the documented pipeline idiom. Updated here:
> `RestConnectionsIT` (two-fn:-params negative test replaces the multi-stage one; test I adds a chained topic
> and per-topic-anchored round-trip assertions), stale scenario-B comments. `ConnectivityFactory` unchanged
> (its RQL+fn: two-param topic is valid under both revisions). Runtime scenarios A–E2 unchanged.
```

And in the `**Status:**` line, replace `DONE, 30/30 green + review-fix runs 11/11 green (...) , NOT pushed` with `REDESIGNED 2026-07-31 — all pre-2026-07-31 run evidence is for the retired rev-1 syntax; re-run per Task 6 of docs/superpowers/plans/2026-07-31-chained-pipeline-filter-redesign.md (ditto-testing repo) pending. NOT pushed.`

- [ ] **Step 5: Compile the system tests (no stack needed)**

```bash
cd /Users/sta1sf3/Develop/projects/Bosch/ditto-ws/ditto-testing_feature__target-topic-pipeline-filter
mvn -pl system test-compile -am -q -DskipTests 2>&1 | tail -5
```
Expected: BUILD SUCCESS. (If `mvn` is not on PATH use `/opt/homebrew/Cellar/sdkman-cli/5.18.2/libexec/candidates/maven/3.9.3/bin/mvn`.)

- [ ] **Step 6: Commit (testing repo)**

```bash
git add system/src/test/java/org/eclipse/ditto/testing/system/connectivity/rest/RestConnectionsIT.java \
        system/src/test/java/org/eclipse/ditto/testing/system/connectivity/AbstractConnectivityITestCases.java \
        docs/superpowers/specs/2026-07-17-target-topic-pipeline-filter-system-tests.md \
        docs/superpowers/plans/2026-07-31-chained-pipeline-filter-redesign.md
git commit -m "test(connectivity): adopt chained pipeline filter param design

The main repo reversed the repeated-fn:-params rule: a topic now carries
at most one RQL and at most one fn: filter param, and several pipeline
conditions chain with '|' inside the single fn: param (the documented
placeholder-pipeline idiom). RestConnectionsIT: the multi-stage negative
test flips into a two-fn:-params negative test; the valid-filters test
gains a chained topic and per-topic-anchored round-trip assertions.
Stale 'RQL head' comments fixed; spec banner rewritten.

Signed-off-by: Aleksandar Stanchev <aleksandar.stanchev@bosch.com>
Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Verification runs against the rebuilt stack + evidence recording

**Files:**
- Modify: `docs/superpowers/specs/2026-07-17-target-topic-pipeline-filter-system-tests.md` (evidence)
- Modify: `.superpowers/sdd/progress.md` (ledger)

**Interfaces:**
- Consumes: everything above, plus a Ditto stack rebuilt from main-repo HEAD (post-Task-4).
- Produces: recorded, dated run evidence for the redesign — closing the critical review finding that no run ever covered the new syntax.

- [ ] **Step 1: USER CHECKPOINT — rebuild & restart the stack**

Ask the user to rebuild the main ditto repo (`mvn install -DskipTests` or their usual flow) and restart the host-run Ditto services (IntelliJ run configurations: Connectivity, Gateway, Policies, Things, ThingsSearch) plus keep the dockerized brokers running. Do not proceed until confirmed.

- [ ] **Step 2: Stack freshness probe**

Dry-run POST a connection whose topic has TWO `fn:` params (`?filter=fn:filter(header:a,'exists')&filter=fn:filter(header:b,'exists')`) via `POST /api/2/connections?dry-run=true` with devops auth: a **stale (rev-1) build accepts** it, the **new build rejects** it with `at most one pipeline filter`. Also probe the chained form the same way: new build validates OK, stale build rejects with `exactly one 'fn:' stage`. Both probes must indicate the NEW build before running suites.

- [ ] **Step 3: Run the REST validation tests (8 pipeline tests)**

```bash
cd /Users/sta1sf3/Develop/projects/Bosch/ditto-ws/ditto-testing_feature__target-topic-pipeline-filter
/opt/homebrew/Cellar/sdkman-cli/5.18.2/libexec/candidates/maven/3.9.3/bin/mvn verify -am -amd --projects=:system \
  -Dtest.environment=local \
  -Dgateway.devops.auth.enabled=true -Dgateway.devops.auth.password=foobar \
  -DfailIfNoTests=false \
  -Dit.test='RestConnectionsIT#createConnectionWithUnknownPipelineFunctionInTargetTopicFilterFails+createConnectionWithMalformedRqlFilterParamAlongsidePipelineFilterParamFails+createConnectionWithTwoRqlTargetTopicFilterParamsFails+createConnectionWithTwoPipelineTargetTopicFilterParamsFails+createConnectionWithLegacyCombinedFilterSyntaxFails+createConnectionWithWhitespaceOnlyTargetTopicFilterFails+createConnectionWithValidPipelineTargetTopicFilters+modifyConnectionRevalidatesPipelineTargetTopicFilters'
```
Expected: 8/8 PASS. If the round-trip assertion of test I fails on the chained substring, read the actual GET body first (Task 5 Step 2c CAUTION) before changing anything.

- [ ] **Step 4: Run one full runtime suite (scenario coverage incl. the factory's two-param connection)**

```bash
/opt/homebrew/Cellar/sdkman-cli/5.18.2/libexec/candidates/maven/3.9.3/bin/mvn verify -am -amd --projects=:system \
  -Dtest.environment=local \
  -Dgateway.devops.auth.enabled=true -Dgateway.devops.auth.password=foobar \
  -DfailIfNoTests=false \
  -Dit.test='Amqp10ConnectivityIT#sendCommandsConsumeEventsFilteredByPipelineOriginatorFilter+sendCommandsConsumeEventsFilteredByCombinedRqlAndPipelineFilter+publishEnrichedSignalsFilteredByPipelineOriginatorFilter+filterLiveMessagesByPipelineOriginatorFilter+consumeEventsFilteredByOriginPipelineFilter+deliverLiveMessagesWithAbsentOriginHeaderForNeOriginPipelineFilter'
```
Expected: 6/6 PASS (scenarios A-E2; scenario B exercises the one-RQL+one-fn: two-param topic end-to-end).

- [ ] **Step 5: Record evidence + close out**

- Spec: replace the pending note from Task 5 Step 4 in the `**Status:**` line with the dated results (e.g. `REDESIGNED 2026-07-31, re-verified same day: RestConnectionsIT 8/8, Amqp10ConnectivityIT 6/6 against ditto <new-HEAD-sha>`), and add a row-block `## Verification evidence (2026-07-31, chained-pipeline redesign)` mirroring the 2026-07-17 table (suites, counts, durations, probe outcome, main-repo HEAD sha).
- Ledger: append a dated entry to `.superpowers/sdd/progress.md` summarizing the redesign commits (both repos, shas) and the run results.
- Commit (testing repo):

```bash
git add docs/superpowers/specs/2026-07-17-target-topic-pipeline-filter-system-tests.md .superpowers/sdd/progress.md
git commit -m "docs(spec): record chained-pipeline redesign verification runs

Signed-off-by: Aleksandar Stanchev <aleksandar.stanchev@bosch.com>
Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Self-Review (performed at plan-writing time)

1. **Spec coverage:** every rule in Global Constraints maps to a task — chaining legal (Task 1), one-pipeline-param arity (Task 2), runtime AND semantics of chained form (Tasks 1+3), docs (Task 4), system tests incl. the review's positive-coverage gap now in chained form (Task 5), and the review's critical never-ran finding (Task 6). The legacy-`rql|fn:` and two-RQL rules are unchanged and stay covered by existing untouched tests.
2. **Placeholder scan:** no TBDs; every code step carries the actual code; doc edits quote exact before/after text.
3. **Type consistency:** `validatePipelineFilter(String, DittoHeaders)`, `partition(List<String>)`, `PartitionedFilters#getPipelineExpressions()` used consistently; test names referenced in Task 6's `-Dit.test` match the names created/kept in Task 5 plus the pre-existing ones verified in the current file.
4. **Known judgment calls encoded:** runtime loops kept list-based deliberately (defensive); one multi-param unit test retained as its lock; `ConnectivityFactory` untouched; round-trip caution for `|` serialization flagged where it can bite.
