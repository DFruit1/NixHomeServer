---
name: grilling
description: Interview the user relentlessly about a plan, decision, design, or idea to expose unresolved assumptions. Use when the user wants to stress-test their thinking, asks to be grilled, or when $grill-me delegates its interview.
---

# Grilling

Map the subject as a decision tree. Walk each branch in dependency order until
the user and agent share an explicit understanding.

Ask exactly one question at a time and wait for the answer. For each question,
include a concise recommended answer and the reasoning behind it so the user
can react to a concrete proposal.

Resolve facts by inspecting the repository, filesystem, tools, or authoritative
sources. Do not ask the user to retrieve facts available to the agent.
Distinguish those facts from decisions: decisions remain the user's, so put
each one to them explicitly.

Use each answer to update the tree and select the next unresolved decision.
Revisit earlier branches when a later answer invalidates an assumption.

When no unresolved branch remains, summarize the shared understanding,
including important constraints, rejected alternatives, and remaining risks.
Do not implement or otherwise act on it until the user confirms that the
understanding is complete.
