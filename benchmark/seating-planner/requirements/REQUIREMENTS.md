# Wedding Seating Optimizer

## Product Requirements Document

**Status:** Draft v0.1  
**Audience:** Product, design, engineering, QA, and implementation agents  
**Primary use case:** Wedding seating-chart creation and last-minute seating changes

---

## 1. Instructions for the Implementing Agent

Treat the numbered `SHALL` statements in this document as product requirements. Do not silently weaken, remove, or reinterpret them. If two requirements conflict, identify the conflict and request a decision before implementation.

The seating engine must use deterministic constraint optimization. A language model may help translate natural-language instructions into proposed structured rules, but it must not be the authoritative seating engine. Users must be able to inspect, edit, and approve every generated rule.

Any numerical thresholds marked **Proposed** are initial product decisions and may be changed by the product owner. They are intentionally explicit so that the requirements remain testable.

---

## 2. Product Purpose

The application helps a wedding planner, couple, or event organizer create a seating chart from a guest list, venue layout, relationship information, and prioritized seating rules.

The system will:

1. Begin with a configurable set of common wedding-seating rules.
2. Accept guests, households, relationships, preferences, and conflicts.
3. Generate an initial seating assignment.
4. Explain rule violations and placement decisions.
5. Allow manual overrides and locked assignments.
6. Recalculate the plan when guests are added or removed.
7. Preserve existing assignments when changes occur near or during the event.

---

## 3. Product Principles

1. **Rules are explicit.** No seating rule may exist only inside a prompt or hidden model context.
2. **Results are explainable.** The organizer must be able to see which rules were satisfied or violated.
3. **Manual decisions take priority.** Locked assignments cannot be changed automatically.
4. **Change strategy depends on timing.** Early changes may reorganize the chart; event-day changes should minimize disruption.
5. **No false success.** The system must report infeasible hard constraints rather than silently violate them.
6. **Private relationship information stays private.** Sensitive notes are excluded from guest-facing materials.

---

## 4. Scope

### 4.1 Included in the Initial Product

- Event and venue configuration
- Table and optional individual-seat placement
- Guest and household management
- Relationship and proximity rules
- Deterministic automatic assignment
- Manual reassignment and locking
- Planning, low-disruption, and event-day recalculation
- Conflict explanations
- Seating-chart versions and undo
- Printable and electronic exports

### 4.2 Out of Scope for the Initial Product

- Invitation design or delivery
- RSVP collection from guests
- Catering orders and meal production
- Vendor payment management
- Travel or hotel coordination
- Fully featured venue CAD or architectural drawing
- Autonomous interpretation of private messages or social-media data

---

## 5. Definitions

| Term                    | Definition                                                   |
| ----------------------- | ------------------------------------------------------------ |
| **Hard constraint**     | A rule the optimizer may not violate unless the user explicitly changes the rule or authorizes a documented exception. |
| **Soft constraint**     | A preference with a priority weight from 1 through 100. The optimizer may violate it when necessary. |
| **Locked assignment**   | A table or seat assignment that automatic recalculation cannot change. |
| **Focal point**         | A user-designated location such as the head table, sweetheart table, stage, or dance floor. |
| **Seating priority**    | The desired proximity of a guest or group to a focal point.  |
| **Disruption**          | Moving an already-assigned guest to a different table. A seat change at the same table is tracked separately. |
| **Eligible guest**      | A confirmed guest, or a pending guest for whom the user has explicitly reserved a seat. |
| **Unresolved conflict** | A combination of hard constraints that cannot all be satisfied. |
| **Rule violation**      | A hard or soft constraint not satisfied by a proposed or applied assignment. |
| **Planning mode**       | Recalculation that may move any guest whose assignment is not locked. |
| **Low-disruption mode** | Recalculation that attempts to improve the chart while limiting table changes. |
| **Event-day mode**      | Recalculation that treats all existing assignments as fixed unless the user explicitly unlocks them. |

---

## 6. Users and Permissions

### Roles

- **Owner:** Manages the event, collaborators, rules, assignments, exports, and deletion.
- **Editor:** Manages guests, rules, assignments, and exports but cannot delete the event or change ownership.
- **Viewer:** Views the current seating chart and permitted exports but cannot modify data.

### Requirements

**FR-001.** The system SHALL allow an event owner to grant and revoke Editor and Viewer access.

**FR-002.** The system SHALL enforce permissions on the server and not rely solely on hidden or disabled user-interface controls.

**FR-003.** The system SHALL record the identity and timestamp of each user who changes a guest, rule, table, assignment, or saved version.

---

## 7. Event and Venue Setup

**FR-004.** The system SHALL allow an authorized user to create an event containing a name, date, venue name, expected guest count, time zone, and at least one designated focal point.

**FR-005.** The system SHALL allow the user to add, edit, duplicate, reorder, and remove tables.

**FR-006.** Each table SHALL have a unique identifier, display name or number, seating capacity, shape, and position on a two-dimensional room layout.

**FR-007.** The system SHALL support round, rectangular, and custom-shaped tables.

**FR-008.** The system SHALL allow the user to rotate and reposition tables on the room layout.

**FR-009.** The system SHALL allow optional seat-level configuration around each table.

**FR-010.** Each configured seat SHALL have a unique identifier and a defined position relative to its table.

**FR-011.** The system SHALL derive adjacent-seat relationships from the configured seat positions.

**FR-012.** If seat positions have not been configured, the system SHALL mark adjacent-seat rules as unevaluable and SHALL NOT report them as satisfied.

**FR-013.** The system SHALL prevent automatic or manual assignments that exceed a table's defined capacity unless the user first changes that capacity.

**FR-014.** The system SHALL calculate proximity between tables using their positions on the room layout.

**FR-015.** The system SHALL allow the user to create named room zones such as Front, Center, Rear, Accessible, Children's Area, and Vendor Area.

---

## 8. Guest Management

**FR-016.** Each guest record SHALL contain a unique identifier, display name, RSVP status, and party or household association.

**FR-017.** A guest record SHALL optionally contain pronouns, age category, meal choice, accessibility needs, relationship categories, seating-priority category, and private notes.

**FR-018.** The system SHALL support the RSVP statuses Confirmed, Pending, Declined, and Cancelled.

**FR-019.** Only Confirmed guests SHALL be assigned automatically unless the user explicitly reserves a seat for a Pending guest.

**FR-020.** The system SHALL support unconfirmed plus-one placeholders that may later be converted into named guest records without losing their assignment or relationships.

**FR-021.** The system SHALL allow guests to be entered individually, entered as a household or party, or imported from a CSV file.

**FR-022.** Before applying a CSV import, the system SHALL display invalid rows, likely duplicate guests, missing required fields, and the number of records that will be created or updated.

**FR-023.** The user SHALL be able to cancel an import without changing event data.

**FR-024.** The system SHALL support named guest groups including Household, Couple, Immediate Family, Extended Family, Wedding Party, Friends, Coworkers, Children, and Vendors.

**FR-025.** The user SHALL be able to create additional guest-group types.

**FR-026.** A guest SHALL be permitted to belong to more than one group.

**FR-027.** Private guest and relationship notes SHALL be excluded from guest-facing screens and exports by default.

---

## 9. Seating Rules

**FR-028.** A newly created wedding event SHALL include an editable wedding-rule template.

**FR-029.** The default template SHALL include proposed rules for couples, households, immediate family, wedding-party members, children, vendors, and guests requiring accessible seating.

**FR-030.** The user SHALL be able to enable, disable, duplicate, edit, and delete each template rule.

**FR-031.** Every active rule SHALL be classified as either a hard constraint or a soft constraint.

**FR-032.** Every soft constraint SHALL have a user-configurable integer priority weight from 1 through 100, where 100 represents the highest soft-rule priority.

**FR-033.** Each rule SHALL identify the guests, groups, tables, zones, or focal points to which it applies.

**FR-034.** The system SHALL support the following guest-relationship rules:

- Assign specified guests to the same table.
- Assign specified guests to adjacent seats.
- Assign specified guests to different tables.
- Maintain a specified minimum distance between guests.
- Place a guest near another guest or group.
- Place a guest away from another guest or group.
- Place a guest within or outside a designated room zone.
- Place a guest near or away from a focal point.
- Assign a guest to or exclude a guest from a specified table.

**FR-035.** A minimum-distance rule SHALL specify either a measurable layout distance or a minimum number of intervening table zones; the term "far apart" SHALL NOT be stored as an executable rule.

**FR-036.** The system SHALL support group rules that keep a household, couple, or other group together at the same table.

**FR-037.** A group rule SHALL define whether splitting the group is prohibited or permitted with a specified soft-rule weight.

**FR-038.** The system SHALL allow seating-priority categories to be ranked relative to a designated focal point.

**FR-039.** The default priority categories SHALL include Wedding Party, Immediate Family, Extended Family, Friends, Coworkers, and Vendors.

**FR-040.** The user SHALL be able to override category priority for an individual guest or group.

**FR-041.** Before optimization, the system SHALL identify contradictory hard constraints, groups larger than every eligible table, unavailable required seats or zones, and insufficient total capacity.

**FR-042.** The system SHALL require user confirmation before converting a hard constraint into a soft constraint.

---

## 10. Automatic Seating Assignment

**FR-043.** The system SHALL generate table assignments for all eligible guests when sufficient capacity exists and the hard constraints are satisfiable.

**FR-044.** When seat-level layouts exist, the system SHALL also generate individual seat assignments.

**FR-045.** The optimizer SHALL satisfy every hard constraint unless the user explicitly authorizes a documented exception.

**FR-046.** After satisfying hard constraints, the optimizer SHALL maximize the weighted total of satisfied soft constraints.

**FR-047.** The optimizer SHALL treat table capacity as a hard constraint in every operating mode.

**FR-048.** Repeated optimization using identical guests, tables, rules, locks, mode, and solver settings SHALL produce the same assignment.

**FR-049.** The result of each optimization SHALL include:

- The number of eligible guests assigned.
- The number of unassigned guests.
- The overall soft-constraint score.
- Every violated soft constraint.
- Every authorized hard-constraint exception.
- The guests affected by each violation or exception.

**FR-050.** If no valid assignment exists, the system SHALL preserve the current seating chart and identify the hard constraints involved in the conflict.

**FR-051.** When no valid assignment exists, the system SHALL recommend at least one corrective action, such as increasing capacity, unlocking an assignment, changing a hard constraint, or adding a table.

**FR-052.** A failed, cancelled, or timed-out optimization SHALL NOT modify the last successfully saved seating chart.

---

## 11. Manual Assignment and Overrides

**FR-053.** The user SHALL be able to assign or move guests using drag-and-drop, seat swapping, and table reassignment controls.

**FR-054.** Before applying a manual change that violates a hard constraint, the system SHALL display the violated rule and require explicit confirmation.

**FR-055.** Before applying a manual change that violates a soft constraint, the system SHALL display the violated rule and its weight.

**FR-056.** The user SHALL be able to record an explanation for an authorized rule violation.

**FR-057.** The system SHALL allow the user to lock a guest to a table, lock a guest to a specific seat, or lock all assignments at a table.

**FR-058.** Automatic recalculation SHALL NOT modify a locked assignment.

**FR-059.** The system SHALL allow authorized users to unlock an assignment.

**FR-060.** The system SHALL provide undo and redo for guest, rule, table, and assignment changes made during the current editing session.

**FR-061.** The system SHALL allow the user to save a named seating-chart version.

**FR-062.** The system SHALL allow the user to compare and restore saved seating-chart versions.

---

## 12. Change-Management Modes

| Mode               | Treatment of existing assignments                            | Intended use                                                 |
| ------------------ | ------------------------------------------------------------ | ------------------------------------------------------------ |
| **Planning**       | Reoptimize every unlocked guest                              | Changes made while the seating chart remains flexible        |
| **Low-disruption** | Preserve assignments where possible and enforce a user-selected movement limit | Changes made shortly before the event                        |
| **Event-day**      | Treat all existing assignments as locked unless explicitly unlocked | Additions and cancellations after seating is effectively final |

**FR-063.** In Planning mode, the system MAY move any guest whose assignment is not locked in order to produce the highest-scoring valid arrangement.

**FR-064.** In Low-disruption mode, the user SHALL specify the maximum number of guests who may be moved to different tables.

**FR-065.** Low-disruption optimization SHALL treat the selected maximum number of table changes as a hard constraint.

**FR-066.** Within the permitted movement limit, Low-disruption mode SHALL minimize the number of table changes before maximizing the soft-constraint score.

**FR-067.** In Event-day mode, the system SHALL treat every existing table assignment as locked unless the user explicitly unlocks it.

**FR-068.** In Event-day mode, the system SHALL assign newly added guests using unoccupied seats without moving previously assigned guests.

**FR-069.** If no valid seat exists in Event-day mode, the system SHALL leave the new guest unassigned and present alternatives ranked by disruption count and violated-rule weight.

**FR-070.** Event-day alternatives SHALL include applicable options such as adding a table, changing a table's capacity, unlocking a specific assignment, or authorizing a rule exception.

**FR-071.** Removing or cancelling a guest in Event-day mode SHALL free that guest's seat without automatically moving another guest.

**FR-072.** Before applying any recalculation, the system SHALL display a comparison showing every guest whose table or seat would change.

**FR-073.** The user SHALL be able to cancel a proposed recalculation without changing the saved seating chart.

---

## 13. Seating-Chart Presentation

**FR-074.** The system SHALL display the room, focal points, zones, tables, seats, guest assignments, locks, and rule violations on a visual seating chart.

**FR-075.** The visual chart SHALL distinguish unassigned guests, assigned guests, locked assignments, and assignments with violations without relying on color alone.

**FR-076.** The user SHALL be able to search for a guest and highlight that guest's assigned table and seat.

**FR-077.** The user SHALL be able to filter guests by RSVP status, party, group, seating-priority category, assignment status, and rule-violation status.

**FR-078.** Selecting a guest SHALL display that guest's assignment, applicable rules, satisfied rules, violated rules, locks, and private notes to authorized users.

**FR-079.** Selecting a table SHALL display its capacity, occupied seats, available seats, assigned guests, locks, and violations.

---

## 14. Export and Printing

**FR-080.** The system SHALL export a printable room seating chart in PDF format.

**FR-081.** The system SHALL export an alphabetical guest-to-table list in PDF and CSV formats.

**FR-082.** The system SHALL export a table-by-table guest list in PDF and CSV formats.

**FR-083.** The system SHALL export individual printable table cards.

**FR-084.** Private guest notes, relationship notes, rule definitions, and override explanations SHALL be excluded from exports by default.

**FR-085.** If an authorized user elects to include private information in an export, the system SHALL display a privacy warning and identify the included fields before generating the file.

---

## 15. Nonfunctional Requirements

**NFR-001 — Optimization performance (Proposed).** The system SHALL generate an initial assignment for 250 guests, 30 tables, and 2,000 active relationship rules within 15 seconds in the documented production test environment.

**NFR-002 — Interactive performance (Proposed).** Excluding optimization, import, and export operations, 95% of user actions SHALL produce visible feedback within 500 milliseconds in the documented production test environment.

**NFR-003 — Autosave (Proposed).** The system SHALL save accepted changes within five seconds after the final user action when network connectivity is available.

**NFR-004 — Recovery.** If an autosave fails, the system SHALL retain the unsaved changes locally, notify the user, and retry after connectivity is restored.

**NFR-005 — Transport security.** All client-server communication SHALL use TLS 1.2 or later.

**NFR-006 — Stored-data security.** Guest, relationship, rule, assignment, and private-note data SHALL be encrypted at rest.

**NFR-007 — Authorization.** Event data SHALL be accessible only to explicitly authorized Owners, Editors, and Viewers.

**NFR-008 — Auditability.** The system SHALL maintain an audit record of imports, rule changes, manual overrides, locks, recalculations, assignment changes, exports containing private data, and version restorations.

**NFR-009 — Deletion.** The Owner SHALL be able to permanently delete an event and its associated guest data. The production retention period for backups must be documented before release.

**NFR-010 — Accessibility.** The web interface SHALL conform to WCAG 2.2 Level AA.

**NFR-011 — Mobile operation.** The event-day interface SHALL support viewport widths from 360 CSS pixels upward without horizontal page scrolling, excluding deliberate scrolling inside the seating-chart canvas.

**NFR-012 — Availability (Proposed).** The production service SHALL maintain 99.9% monthly availability, excluding maintenance announced at least 48 hours in advance.

**NFR-013 — Data integrity.** A failed, interrupted, or cancelled write SHALL leave either the previously committed state or the fully committed new state; it SHALL NOT expose a partially committed seating chart.

**NFR-014 — Browser support.** The application SHALL support the current and immediately preceding major releases of Chrome, Edge, Firefox, and Safari at the time of each production release.

---

## 16. Acceptance Scenarios

### AC-001: Generate an Initial Chart

**Given** an event with 100 confirmed guests, sufficient table capacity, and satisfiable hard constraints  
**When** the user runs Planning-mode optimization  
**Then** every confirmed guest is assigned without exceeding table capacity  
**And** every hard constraint is satisfied  
**And** the system displays the resulting soft-constraint score and violations.

### AC-002: Detect an Impossible Couple Assignment

**Given** two guests have a hard rule requiring the same table  
**And** each guest is locked to a different table  
**When** the user requests recalculation  
**Then** the system does not change the current chart  
**And** identifies the same-table rule and both locks as an unresolved conflict.

### AC-003: Respect a Manual Lock

**Given** a guest is locked to Table 4  
**When** the user runs any optimization mode  
**Then** that guest remains assigned to Table 4.

### AC-004: Add a Guest During Planning

**Given** an existing chart and a newly confirmed guest  
**When** the user runs Planning-mode optimization  
**Then** the optimizer may move unlocked guests  
**And** presents the complete proposed-change comparison before applying it.

### AC-005: Add a Guest on the Event Day

**Given** an existing chart in Event-day mode with at least one valid open seat  
**When** a new guest is added  
**Then** the new guest is assigned to an open seat  
**And** no previously assigned guest changes tables.

### AC-006: No Valid Event-Day Seat

**Given** an existing chart in Event-day mode with no seat satisfying all hard constraints  
**When** a new guest is added  
**Then** the guest remains unassigned  
**And** the system presents ranked corrective options  
**And** no existing assignment changes without explicit user authorization.

### AC-007: Remove an Event-Day Guest

**Given** a seated guest in Event-day mode  
**When** that guest is marked Cancelled  
**Then** the guest's seat becomes available  
**And** no other guest is moved automatically.

### AC-008: Protect Private Notes

**Given** guests and relationship rules containing private notes  
**When** the user generates the standard guest-to-table PDF  
**Then** none of the private notes, relationship rules, or override explanations appears in the exported file.

---

## 17. Implementation Guardrails

1. Represent rules as structured data with explicit subjects, targets, type, hardness, weight, and parameters.
2. Use a deterministic constraint solver, such as OR-Tools CP-SAT, for assignments and optimization.
3. Persist the solver configuration or seed needed to reproduce an assignment.
4. Separate constraint evaluation from user-interface presentation.
5. Store manual overrides and locks as domain data rather than transient interface state.
6. Never claim that an unevaluated rule is satisfied.
7. Require confirmation before applying changes; optimization results are proposals until accepted.
8. Treat an LLM-generated rule as a draft until the user approves its structured representation.

---

## 18. Product Decisions Still Required

The following decisions should be resolved before final architecture and release planning:

1. Whether the first release requires real-time multiuser editing or only shared access.
2. Whether table positions use a scaled physical measurement or relative canvas coordinates.
3. Whether adjacent-seat assignment is required for the MVP or may be introduced after table-level assignment.
4. Whether private conflict notes require an additional permission separate from Editor access.
5. The production limits for guests, tables, rules, events, and collaborators.
6. The backup-retention period following permanent event deletion.
7. Whether the system will provide a natural-language rule assistant in the first release.
8. Whether the product is wedding-specific in branding or supports other seated events from launch.
