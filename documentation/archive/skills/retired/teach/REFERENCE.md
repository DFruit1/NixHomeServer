---
name: teach
description: Teach the user a new skill or concept over multiple sessions using the current directory as a stateful teaching workspace. Use only when the user explicitly invokes $teach or asks to begin a durable, workspace-backed course of study rather than requesting a one-off explanation.
---

# Teach

Treat the current directory as a stateful teaching workspace. The user intends
to learn the topic over multiple sessions.

## Maintain the teaching workspace

Use these files and directories to preserve learning state:

- `MISSION.md`: Record why the user wants to learn the topic. Follow
  [MISSION-FORMAT.md](./MISSION-FORMAT.md).
- `RESOURCES.md`: Curate trusted knowledge sources and practitioner
  communities. Follow [RESOURCES-FORMAT.md](./RESOURCES-FORMAT.md).
- `GLOSSARY.md`: Maintain the canonical terminology the user has demonstrated
  they understand. Follow [GLOSSARY-FORMAT.md](./GLOSSARY-FORMAT.md).
- `learning-records/*.md`: Record non-obvious learning, prior knowledge,
  corrected misconceptions, and mission changes. Follow
  [LEARNING-RECORD-FORMAT.md](./LEARNING-RECORD-FORMAT.md).
- `lessons/*.html`: Store numbered, self-contained lessons as
  `0001-<dash-case-name>.html`.
- `reference/*.html`: Store printable cheat sheets, algorithms, glossaries,
  syntax references, or other compressed learning aids.
- `assets/*`: Store reusable lesson components such as stylesheets, quiz
  widgets, simulators, and diagram helpers.
- `NOTES.md`: Record teaching preferences and temporary working notes.

Create directories lazily. Do not overwrite an existing learning workspace.
Read its mission, records, glossary, resources, notes, and reusable assets
before deciding what to teach next.

## Ground every lesson in the mission

Clarify the concrete real-world outcome before teaching. If `MISSION.md` is
missing or vague, ask one focused question at a time until the mission is
specific enough to guide lesson selection.

Keep one mission per workspace. Confirm with the user before changing it, then
record a material mission shift in a learning record.

## Teach within the learner's reach

Choose one tightly scoped lesson in the user's zone of proximal development:
challenging enough to require effort, but close enough to their current
knowledge that they can succeed.

Infer that zone from:

- demonstrated understanding in learning records;
- prior knowledge the user reports;
- misconceptions revealed by exercises or questions;
- the next capability required by the mission.

Do not mistake exposure or fluent short-term recall for mastery. Build durable
storage strength with retrieval practice, spacing across sessions, and
interleaving when practicing related skills.

## Ground knowledge in sources

Research important factual claims instead of trusting parametric memory.
Prefer primary sources, recognized experts, peer-reviewed work, and strongly
moderated practitioner communities. Curate useful sources in `RESOURCES.md`
with a note explaining what each source supports.

Use citations in lessons. Keep required knowledge easy to acquire so working
memory remains available for understanding.

## Build skills through feedback

After explaining only the knowledge needed for the current skill, require the
learner to use it. Prefer short, realistic exercises with an immediate
feedback loop.

Use interactive quizzes, browser exercises, simulations, or guided real-world
steps when they suit the topic. For multiple-choice quizzes, keep answer
lengths as equal as practical so formatting does not reveal the answer.

Record learning only after the user demonstrates it. Do not turn learning
records into session logs.

## Produce compact lessons

Create one short HTML lesson per session or tightly scoped learning unit. Give
the learner one tangible win tied directly to the mission.

Each lesson must:

- use clean, readable, print-friendly typography;
- reuse existing components from `assets/`;
- add new reusable components to `assets/` instead of duplicating them inline;
- link to relevant lessons and reference documents with HTML anchors;
- cite and recommend one high-trust primary resource;
- include a brief invitation to ask follow-up questions;
- include practice and a feedback mechanism where the topic permits it.

Create a shared stylesheet as the first reusable asset. If a browser preview is
available, open the completed lesson for the user and inspect it.

## Compress and connect the learning

Create or update reference documents alongside lessons when the topic benefits
from durable lookup material. Prefer algorithms, flowcharts, syntax examples,
exercise sequences, and compact glossaries over lesson summaries.

Promote a term to `GLOSSARY.md` only after the user can use it correctly. Use
the glossary's canonical terms consistently in future lessons.

When judgment requires experience beyond research, answer as far as reliable
evidence permits, then suggest a reputable community where the learner can
test the skill in practice. Respect a preference not to join communities.
