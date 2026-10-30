# Wait for agents and receive their work

The agent running this skill coordinates the pass in the thread where it was
invoked. Discover and record that thread's exact ID from the runtime; never
hardcode a thread from an earlier run. Send completion handoffs back there.

## Establish participants and request handoffs

Use T3's paginated `t3_thread_list` for the current project, including subagents,
and focused `t3_thread_read` calls to associate active tasks with the gathered
paths, dependencies and worktrees. Include running, queued, preparing and
waiting work that contributes to this pass, even when its checkout is clean.
Exclude the coordinator itself, unrelated work and historical completed tasks.
Unknown ownership needs clarification before editing the affected files.

For each participating top-level agent, use `t3_thread_send` with a stable
`clientRequestId` and a non-interrupting mode to send a scoped coordination
request. Do not restart/cancel work, launch a replacement conversation or wake
unrelated idle agents. This workflow authorizes these internal requests, not
external messages. For example, substitute the actual thread ID and scope:

> I am coordinating finish-and-switch for <scope> in thread <coordinator ID>.
> Please finish your current work independently; you do not need to wait for my
> integration. Tell me your checkout, owned paths, dependencies and known issues
> now, including issues I can address without overlapping your work. Once your
> current work and its child tasks finish, send an explicit completion handoff
> to <coordinator ID> using t3_thread_send. Include exact commits or a stable
> dirty-content manifest, paths, checks/results, remaining issues and whether
> you have stopped writing those paths and handed them to me for integration.
> Validated commits in your checkout are welcome. Please flag any intended
> shared-branch integration or deployment so we can coordinate it.

Record each agent's acknowledgment, early issues and eventual handoff separately.
Delivery or acknowledgment of the request does not mean the work is finished.
Keep current scope finite; do not ask agents to start another backlog of work.

Parents own their existing descendants: ask the parent to collect its children's
results and explicitly include their scope/revisions/issues in its handoff to
the coordinator. A child need not wait for this coordination pass to finish.
For the coordinator's own delegated implementation tasks, require the terminal
result to explicitly hand back the same information; the native completion
delivery to this thread counts when that content is present and no nested work
remains. If it is missing, request the missing evidence. New independent review
rounds still use a fresh `delegate_task`, never a thread-send continuation.

## Work while waiting

Review existing diffs, repo state, dependencies and unowned unfinished work.
Read active work as provisional evidence; do not approve, transfer or commit it
as final while its author is changing it. Work on non-overlapping fixes in an
isolated checkout and share useful findings with the owning agent. Obtain an
explicit transfer of ownership before fixing a path another agent owns.

Use incoming completion messages and native task notifications to resume the
pass. If no independent work remains, yield with the outstanding handoffs named
and resume when notified. Preserve the ledger in the invoking thread/task so
resumption retains the participant list, received handoffs and next action.
Do not busy-poll, spawn watcher agents, add recurring schedules or send repeated
unchanged requests. A targeted status request is appropriate for a concrete
missing input or evidence of stale status; silence is never permission to proceed.

## Close the handoff phase

Before the final combined commit, integration/publication or guarded deployment:

1. Every participant must have explicitly reported its current work finished
   and handed it to this invoking thread, including its descendants. Idle,
   completed, failed or cancelled status alone, a timeout, or a clean checkout
   is insufficient. Failed/unreachable agents leave an unresolved handoff;
   recover through supported task tools or report the specific missing input.
2. Verify the handed-over commit or content manifest resolves, accounts for
   staged/unstaged/new source, and matches the stable source paths. Confirm
   the writer has released those paths for integration. Record checks and
   remaining issues as work to resolve, not as successful completion evidence.
3. Re-list relevant agent work and recheck repo/worktree state. Include new
   relevant writers and changed handed-over content in the ledger and obtain
   fresh handoffs for that scope. Do not wait on unrelated work or make later
   read-only reviewers wait for an integration they are supposed to review.
4. Resolve handed-over issues within scope, then perform the skill's combined
   validation, independent review, final commits/publication and guarded deploy.
   Explicitly released remaining fixes can be taken over by the coordinator;
   unfinished requested work cannot be silently excluded. Only established
   user authorization can defer a required participant/change. Never treat a
   missing handoff as a deferral or start deployment to fill the waiting time.
