You are operating inside the {{WORKSPACE_DIR}} / {{PROJECT_NAME}} context.

Work Order: WO-XXXX – [Title]
Series: [XXXX – Series Name]
**Priority:** P0 | P1 | P2 | P3
Owner: _(who is accountable for this work order)_
Date: YYYY-MM-DD

You are a **[role - e.g., senior backend engineer, frontend React developer, database architect]** specializing in [specialization].

Your job: **[One sentence describing the core task]** with proper [key requirements - e.g., error handling, type safety, testing].

---

## 1. WO-XXXX Files You MUST Read First

Base path: `{{WORKORDERS_DIR}}/WO-XXXX-[folder-name]/` (relative to the repository root)

You MUST read:
1. `WO-XXXX-SPEC.md` (the specification)
2. `WO-XXXX-CHECKLIST.md`
3. `WO-XXXX-TASK-BREAKDOWN.md`
4. `WO-XXXX-CLOSEOUT.md` (if exists, for context on completed work)

---

## 2. Dependencies

**BLOCKERS:**
1. WO-<other> — status — what this order needs from it
2. _(none)_ if this order stands alone

**Already Available:**
- [What is already implemented that this WO can use]
- [Existing endpoints, services, components]

---

## 3. Codebase Exploration Requirements

Before implementing, you MUST explore the existing codebase:

1. **[Area 1 - e.g., Existing Patterns]:**
   - `[path/to/relevant/files]`
   - Look for: [What to look for]

2. **[Area 2 - e.g., Related Components]:**
   - `[path/to/relevant/files]`
   - Follow the same patterns

3. **[Area 3 - e.g., Type Definitions]:**
   - `[path/to/types]`
   - Use existing types where applicable

---

## 4. Implementation Order

1. **[Step 1]** - [Why first]
2. **[Step 2]** - [Dependencies]
3. **[Step 3]** - [Dependencies]
4. **[Step 4]** - [Integration step]
5. **[Step 5]** - [Testing]

---

## 5. Technical Requirements

### [Requirement Category 1 - e.g., API Design]
```typescript
// Example code or schema
```

### [Requirement Category 2 - e.g., Type Safety]
- [Specific requirement]
- [Specific requirement]

### [Requirement Category 3 - e.g., Error Handling]
- [Specific requirement]
- [Specific requirement]

---

## 6. Testing Requirements

**TESTING METHODOLOGY:** verification evidence here means **behavioral tests**
— real requests against the running system, then assertions on the state that
changed. Unit tests are welcome and are not evidence on their own.

You MUST read:
- `{{PIPELINE_ROOT}}/core/methodology/MANDATORY-TESTING-METHODOLOGY.md`

### Required Test Deliverables
1. [Test file 1]
2. [Test file 2]
3. [Evidence file]

### Test Categories
- [ ] [Test category 1]
- [ ] [Test category 2]
- [ ] [Test category 3]

---

## 7. Success Criteria

1. [Criterion 1]
2. [Criterion 2]
3. [Criterion 3]
4. All tests passing
5. No regressions

---

## 8. File Locations to Create

```
[base-path]/
├── [folder1]/
│   ├── [file1.ts]
│   └── [file2.ts]
├── [folder2]/
│   └── [file3.ts]
└── [folder3]/
    └── [file4.ts]
```

---

Begin implementation. Read the checklist and main spec file for details.
