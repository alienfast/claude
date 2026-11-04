---
paths:
  - "**/*.xlogic"
---

# Flying Logic (.xlogic) Rules

Rules for editing Flying Logic Current Reality Trees (CRTs) and other thinking-process diagrams stored as `.xlogic` XML.

## Vertex and edge IDs share a namespace

Flying Logic looks up elements by `eid` without disambiguating vertex from edge. If a vertex and an edge share the same eid, double-clicking the vertex returns the edge — producing a `NullPointerException` in the UI thread. **A vertex eid and an edge eid must never coincide.** Allocate every new eid above the highest eid of either kind in the file. The files seen so far interleave vertex and edge eids rather than splitting them into ranges, so do not assume a range convention; check for a collision by listing both sets of eids.

## Update edge-order attributes when renumbering

`inEdgeOrder` and `outEdgeOrder` on vertices reference edge eids. After renumbering edges, update both attributes on every affected vertex. Verify with:

```bash
grep -nE '(in|out)EdgeOrder' file.xlogic
```

Flying Logic auto-populates these on save when edges are added. If an attribute lists an edge eid that no longer exists, expect rendering crashes.

## File reload behavior

Flying Logic does NOT watch the file system. After editing the XML externally:

1. **Close Flying Logic without saving.** In-memory state will overwrite your edits otherwise.
2. Reopen the file.
3. Verify changes loaded before continuing.

Crashes with `bG.actionPerformed` / `FLDocument.t` in the stack typically mean the editor's in-memory model is desynced from the file. Close-without-save → reopen.

## Iterative CRT process

CRTs are built in passes. Don't try to write a perfect tree in one sitting.

1. **Capture nodes** for known UDEs and structural facts.
2. **Connect first, prove sufficiency later.** Draw the causal arrow even if a single hop feels too big — note the insufficiency for a later pass.
3. **Look for convergence.** Many UDEs should trace back to few root causes (Archimedes points). If the bottom row is wide, more roots are likely hiding.
4. **Refine causality** by inserting intermediate effects until each arrow passes the sufficiency test ("does this cause alone, or this AND-cluster, actually produce the next effect?").
5. **Check for negative reinforcing loops** — effects that exacerbate their own causes.

Each pass should explicitly note what's still insufficient or unconnected. Convergence is the goal, not coverage.

## Referring to nodes in conversation

The user typically cannot see eids in the rendered diagram. When citing a node, **always include both the eid and the first ~5 words of the title:**

> ✓ "eid=18 'The system does not confirm an account…'"
> ✗ "eid=18"
> ✗ "the account-confirmation node"

This lets the user match the node by reading without searching the file.

## Node type semantics

Flying Logic offers multiple entity classes. In a CRT, only two apply:

- **Un-Desirable Effect** — a node that represents the gap between current reality and the strategic goal (or one of its supporting necessary conditions). UDEs are typically *near the top* of the tree, but classification is **functional, not topological**: a node is a UDE because of *what it means* (an observable contradiction of an SIO requirement), not because of where it sits in the graph. UDEs may have outgoing edges — feeding other UDEs, feeding the apex, or participating in negative reinforcing loops back into causes lower in the tree.
- **Intermediate Effect** — everything else: structural facts, mechanisms, and observable conditions in current reality that are *not* themselves contradictions of an SIO requirement, but contribute to one. Examples: "The system does not confirm an account belongs to an org," "Counterparties are well known across the b→b industry."

Position in the graph distinguishes structural roles among IEs and UDEs but does NOT determine class:

- **Root cause:** no incoming arrows + outgoing. Usually an IE (a structural fact); occasionally a UDE if the topmost contradiction is also primitive.
- **Intermediate position:** incoming + outgoing. Class is IE *or* UDE based on whether the node represents an SIO contradiction.
- **Apex:** incoming + (typically) no outgoing. Usually the root UDE — a contradiction of an NC. Negative reinforcing loops can give an apex outgoing edges back into the tree.

Per Dettmer (*Strategic Navigation*, ch. 7, p. 106): UDEs *"represent the gap between current reality and the strategic goal, or one of its supporting necessary conditions."* Negative reinforcing loops are explicitly endorsed: *"an arrow leads from an effect higher in the tree back down to a cause lower in the tree."* Do not use topology as a strict UDE-vs-IE classifier.

Do **not** use these classes in a CRT:

- `Precondition` / `Necessary Condition` — Goal Tree / Future Reality semantics ("must hold for X to be achieved"). Forward-looking; mixes vocabularies in a CRT.
- `Action` — Future Reality / Strategy & Tactics. Describes interventions, not current reality.
- `Goal` / `Critical Success Factor` — anchors for a Goal Tree, not a CRT (though they may be added alongside to test whether top-level UDEs contradict the CSFs they're meant to violate).

## Wording: "do not" over "cannot"

Prefer "do not" for system facts. "Cannot" implies architectural impossibility; "do not" preserves the truth that the structural choice is changeable — which is the whole point of CRT analysis.

> ✓ "Organizations do not own accounts"
> ✗ "Organizations cannot own accounts"

## Phrase UDEs as observable outcomes, not architecture

UDEs describe the *visible negative effect*, not the system's design. Architecture goes in the root causes / IEs below.

> ✓ "Senders cannot tell whether instructions are authentic"
> ✗ "The system does not provide a verified credential"

## Verify before asserting what's "missing"

Before claiming the system lacks something, check the schema, code, or docs. A table or relation may exist with limited semantics — be precise about *what aspect* is missing rather than asserting the whole concept doesn't exist. ("`orgs` table exists but has no KYB record, owned accounts, or designated agents" — not "no first-class organizational identity.")

## Reference (optional)

For deeper questions about CRT methodology — sufficiency rules, the seven categories of legitimate reservation, Archimedes points, building Goal Trees, transitioning a CRT into a Future Reality Tree — consult H. William Dettmer, *Strategic Navigation: A Systems Approach to Business Strategy* (basefund keeps a text copy under `doc/books/strategic-navigation/`).

Don't read it preemptively. Reach for it when a question goes beyond the conventions in this file — e.g., when the user asks about a process step ("how do we transition into transformation?") or when sufficiency analysis is unclear.
