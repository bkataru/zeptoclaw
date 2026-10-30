# Fix seven open zeptoclaw defects before Barvis runs

* **Author:** bkataru
* **Date:** 2026-10-30

## Overview

One code change covers seven public bugs: stale replay (#1), stacked permanent retries (#2), an oversized NVIDIA request (#3), a slow SIGTERM (#4), the auth token printed at startup (#5), the vision env var (#15), and a model pointer left on a fallback after auth failure (#16). The checks are offline. Barvis stays stopped, with the host unit's `ExecStart=/bin/false`, until all seven are in one binary. The private Barvis incident is a note for #1, not a second implementation.

A reply that has already been produced is still sent. A pending row is skipped only when its enqueue time is missing or older than 600 seconds at the moment replay is about to run it. A young row whose model call was cancelled is left in the file with its original time. Skipping a row deletes it and does not write the seen ledger.

## Analysis

A pending row is the crash record. It is written before the model call and removed after a send, or after the turn function returns an error. The file stores an id, a chat, a body, whether the operator sent it, and whether the chat is direct. It does not store a time. Replay answers every row and does not consult the seen ledger. On every WhatsApp connect, including a reconnect in the same process, another replay thread starts. Two of those threads can answer the same row unless replay of a given row is single-flight.

Rows already on disk have no time. A missing time is already old: replay removes the row and does not call the model. Nothing stamps a missing time as "now", including a rewrite of the file. A flag in the line does not survive. The writer rebuilds each line from a fixed set of fields, and the previous binary ignores fields it does not know. Removing the row is the only skip that binary also honors.

Removing the row does not stop WhatsApp from handing the same message back as a normal inbound. That path uses `gateway-inbound-ledger.json`, which drops ids after 2000, and replay does not write it. This pass accepts that gap. The three-minute fingerprint is not the age rule. It matches the same text under a new message id, and replay does not read it.

The age window is 600 seconds. That is longer than the parked 300 second model deadline, so a crash during one slow reply can still be recovered. A row that sat through an outage longer than 600 seconds is answered only if this rule is wrong; under this rule it is deleted. 600 seconds is also the stuck-turn warning default. These are different clocks and must not be the same setting.

SIGTERM does not delete a young row and does not rewrite its time. If a reply has already been produced, it is sent and the row is then removed. If the model call has not produced a reply, the call is abandoned and the row stays. The next connect answers it if it is still younger than 600 seconds. A kill from outside never runs this path, so the same original time is what the next connect sees.

The permanent-error pile-up is three loops that each allow three tries. The budget is that existing three, owned by the turn. The outer loops do not call the model again after a permanent failure. Media tools keep their own three tries and swallow the error into the tool result, so one image rejection does not spend the text turn's three. HTTP 401 is permanent: it spends the text budget, and the client is put back on the model it was constructed with before the next try. Timeout, 429, 5xx, and network errors stay unbounded, and those waits must return when shutdown is set.

Message counts are already capped. The bytes in one request are not. One tool result can be 64KB, past a body a smaller model has rejected at about 33KB. The serialized request is trimmed in memory to 32KB before it is sent. The system prompt, the current user message, and each tool call with its result are kept or dropped together. If that protected prefix is already over 32KB, it is sent anyway. Journals, `MEMORY.md`, and transcripts are not rewritten. The model is not called to summarize. Dropping the oldest message is not the trim: that drops the system prompt first.

SIGTERM today only sets a flag. The accept loop notices it when accept fails. The WhatsApp reader stops on a different flag, which shutdown never sets. Backoff sleeps run as long as 180 seconds, and a model call that hits the deadline detaches. Shutdown must unblock those waits and leave them within 5 seconds. A send already in hand may finish; a call still inside the model may not. The unit file in the repo still starts the real binary. The host pin that keeps Barvis stopped is a different file and is not edited.

The vision variable is applied only in the block that also replaces the primary model, the fallbacks, the image model, the completion budget, and the timeout. It must be applied only when `NVIDIA_VISION_MODEL` is set, and that assignment must not move the other fields. The startup banner prints the gateway token twice. The process already refuses to start when the token is missing.

## Goals vs. Non-Goals

* **In-Scope Goals:**
  * #1: enqueue time written once, preserved across rewrite. Replay age is 600 seconds, checked before each row runs. Missing or future time is old. The row is removed and the model is not called. A young row is answered. Replay of one row is single-flight. The doc names `gateway-inbound-ledger.json` and the real field names.
  * #2: one permanent budget of 3 for the text turn. Outer loops do not spend it again. Media tools keep a separate 3 and do not fail the turn. Timeout, 429, 5xx, and network stay unbounded and observe shutdown.
  * #3: trim the in-memory request to 32KB before send, with the protected prefix above. No extra model call. No journal rewrite.
  * #4: SIGTERM unblocks accept, the WhatsApp socket, and the model wait within 5 seconds. A produced reply is sent. An unproduced reply leaves the pending row and its original time. The host unit is not edited.
  * #5: the banner says a token is configured and does not print it.
  * #15: `NVIDIA_VISION_MODEL`, when set, replaces only the vision model. Primary, fallbacks, completion budget, and timeout stay on the file unless `NVIDIA_MODEL` is set.
  * #16: every return from the chat call restores the model the client was constructed with, including auth failure.
* **Out-of-Scope Non-Goals:**
  * #6, #7, and #8 stay as already decided. #9 through #14 stay closed.
  * Barvis does not start. The host `ExecStart=/bin/false` pin is not restored in this pass.
  * A skipped row is not written to the seen ledger. A later live redelivery can still be answered.
  * Old journal lines that already contain the token are not scrubbed.
  * The private incident is not a second code change.

## Alternatives Weighed

* One shared module for all seven changes. Rejected. The token line, the vision flag, and the model-pointer restore do not share data with the queue.
* A skip flag or a second queue inside the pending file. Rejected. The writer drops unknown fields, and the previous binary would replay a flag it does not understand.
* Treating a missing timestamp as now. Rejected. The stopped process's backlog would be answered on the first connect.
* An age window of a few minutes. Rejected after review. It is shorter than one parked model deadline, so a crash during a normal slow reply deletes the recovery the pending file exists to provide.
* Removing a young row on SIGTERM. Rejected. A cancelled young turn stays, and the next connect answers it if it is still inside 600 seconds. A kill from outside cannot do better than that.
* Writing the skipped id into the seen ledger. Rejected. Deleting the pending row is the whole skip. A later live redelivery can still be answered, including after the 2000-id cap drops an older id.
* Reusing the three-minute content fingerprint as the age rule. Rejected. Replay does not read it.
* Putting the permanent budget on the model client, or making one media rejection spend the text turn's three. Rejected. Media builds a new client and returns the failure as tool text.
* Calling the model to summarize history, or trimming by dropping the oldest message. Rejected. One spends the deadline. The other drops the system prompt and can split a tool call from its result.
* Editing the host unit. Rejected. That pin is what keeps Barvis stopped.

## Key Decisions & Staging for Next Steps

* Seven bugs, one binary, offline checks, gateway stays down until all seven are in.
* Enqueue time is unix seconds, written once. Missing or future means already old. Never stamp "now".
* Replay skips a row at or above 600 seconds. The setting is not the fingerprint and not the stuck-turn warning.
* A young cancelled row stays, with its original time. A produced reply is sent, then the row is removed.
* A skip deletes the pending row and does not write the seen ledger.
* Permanent text budget is 3, not multiplied by the outer loops. Media keeps its own 3. HTTP 401 spends the text budget and restores the constructed model.
* Request body cap is 32KB, in memory only. The protected prefix is sent even if it is larger.
* Shutdown waits return within 5 seconds. The host unit is untouched.
* Vision override and the token banner are separate from the model-env block.

`/skill:egm-draft` can take this file as its intake. It should not reopen the choices above unless the draft finds a code fact that makes one of them impossible.
