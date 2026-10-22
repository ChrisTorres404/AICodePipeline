#!/usr/bin/env node
/**
 * Behavioral Test Coverage Calculator
 *
 * Not a runner: it runs nothing. It reads a verification document one of the
 * runners already produced and reports how much of it is actually backed by
 * execution — how many tests were run, how many passed, and how many are still
 * NOT EXECUTED. A plan is not coverage.
 *
 * The summary it writes lands in the same results directory every runner uses
 * (TEST_RESULTS_DIR, resolved by harness/lib/paths.sh), so nothing it produces
 * is written into the tree the evidence is fingerprinted against.
 */

const fs = require('fs');
const path = require('path');

// Parse test harness/verification markdown
function parseTestDocument(filePath) {
  if (!fs.existsSync(filePath)) {
    console.error(`Error: File not found: ${filePath}`);
    process.exit(1);
  }

  const content = fs.readFileSync(filePath, 'utf8');

  // Extract test IDs and status from markdown
  // Matches: | 1.1 | Category | Description | EXECUTED — PASS | or
  //          **Status:** EXECUTED — PASS
  // Em dash, en dash or hyphen, as every other status reader accepts.
  const testRegex = /(?:\|\s*(\d+\.\d+)\s*\|.*?\|\s*(EXECUTED [—–-] PASS|EXECUTED [—–-] FAIL|NOT EXECUTED[^|]*)\s*\||Test\s+(\d+\.\d+):.*?\n.*?\*\*Status:\*\*\s*(EXECUTED [—–-] PASS|EXECUTED [—–-] FAIL|NOT EXECUTED[^*]*))/gs;

  const tests = [];
  let match;

  while ((match = testRegex.exec(content)) !== null) {
    const testId = match[1] || match[3];
    const status = (match[2] || match[4]).trim();

    if (testId) {
      tests.push({
        id: testId,
        status: status,
        executed: status.startsWith('EXECUTED'),
        passed: /^EXECUTED [—–-] PASS$/.test(status),
        failed: /^EXECUTED [—–-] FAIL$/.test(status)
      });
    }
  }

  return tests;
}

// Calculate coverage statistics
function calculateCoverage(tests) {
  const total = tests.length;
  const executed = tests.filter(t => t.executed).length;
  const passed = tests.filter(t => t.passed).length;
  const failed = tests.filter(t => t.failed).length;
  const notExecuted = total - executed;

  return {
    total,
    executed,
    passed,
    failed,
    notExecuted,
    executionRate: total > 0 ? (executed / total * 100).toFixed(1) : 0,
    passRate: executed > 0 ? (passed / executed * 100).toFixed(1) : 0,
    overallCoverage: total > 0 ? (passed / total * 100).toFixed(1) : 0
  };
}

// Generate badge
function generateBadge(coverage) {
  const rate = parseFloat(coverage.overallCoverage);

  if (rate >= 95) return { text: 'EXCELLENT', color: 'green' };
  if (rate >= 80) return { text: 'GOOD', color: 'green' };
  if (rate >= 60) return { text: 'ACCEPTABLE', color: 'yellow' };
  return { text: 'NEEDS WORK', color: 'red' };
}

// Main execution
const args = process.argv.slice(2);

if (args.length === 0) {
  console.error('Usage: node calculate-coverage.js <path-to-verification-report.md>');
  console.error('');
  console.error('Example:');
  console.error('  node calculate-coverage.js {{WORKORDERS_DIR}}/WO-0101-example/WO-0101-VERIFICATION.md');
  console.error('');
  console.error('Set COVERAGE_SUMMARY_FILE to control where the summary is written');
  console.error('(default: $TEST_RESULTS_DIR/coverage-summary.txt, else results/).');
  process.exit(1);
}

const filePath = args[0];
const tests = parseTestDocument(filePath);
const coverage = calculateCoverage(tests);
const badge = generateBadge(coverage);

// Display report
console.log('');
console.log('╔════════════════════════════════════════════════════════╗');
console.log('║   Behavioral Test Coverage Report                      ║');
console.log('╚════════════════════════════════════════════════════════╝');
console.log('');
console.log(`File:             ${path.basename(filePath)}`);
console.log(`Analyzed:         ${new Date().toLocaleString()}`);
console.log('');
console.log('Test statistics:');
console.log('─────────────────────────────────────────────────────────');
console.log(`  Total Tests:      ${coverage.total}`);
console.log(`  Executed:         ${coverage.executed} (${coverage.executionRate}%)`);
console.log(`  Passed:           ${coverage.passed}`);
console.log(`  Failed:           ${coverage.failed}`);
console.log(`  Not Executed:     ${coverage.notExecuted}`);
console.log('');
console.log('Coverage metrics:');
console.log('─────────────────────────────────────────────────────────');
console.log(`  Execution Rate:   ${coverage.executionRate}%`);
console.log(`  Pass Rate:        ${coverage.passRate}% (of executed)`);
console.log(`  Overall Coverage: ${coverage.overallCoverage}%`);
console.log('');
console.log(`Overall grade:    ${badge.text}`);
console.log('');

// Breakdown by status
console.log('Test breakdown:');
console.log('─────────────────────────────────────────────────────────');

const passedTests = tests.filter(t => t.passed);
const failedTests = tests.filter(t => t.failed);
const notExecutedTests = tests.filter(t => !t.executed);

if (passedTests.length > 0) {
  console.log(`  PASSED (${passedTests.length}):`);
  passedTests.slice(0, 5).forEach(t => console.log(`     - Test ${t.id}`));
  if (passedTests.length > 5) console.log(`     ... and ${passedTests.length - 5} more`);
  console.log('');
}

if (failedTests.length > 0) {
  console.log(`  FAILED (${failedTests.length}):`);
  failedTests.forEach(t => console.log(`     - Test ${t.id}`));
  console.log('');
}

if (notExecutedTests.length > 0) {
  console.log(`  NOT EXECUTED (${notExecutedTests.length}):`);
  notExecutedTests.slice(0, 5).forEach(t => console.log(`     - Test ${t.id}`));
  if (notExecutedTests.length > 5) console.log(`     ... and ${notExecutedTests.length - 5} more`);
  console.log('');
}

console.log('─────────────────────────────────────────────────────────');
console.log('');

// Write summary to file for CI/CD
const summaryContent = `Behavioral Tests: ${coverage.overallCoverage}% Coverage
Total: ${coverage.total} | Passed: ${coverage.passed} | Failed: ${coverage.failed} | Not Executed: ${coverage.notExecuted}
Status: ${coverage.failed === 0 && coverage.executed > 0 ? 'ALL PASS' : coverage.failed > 0 ? 'FAILURES' : 'PENDING'}
`;

// One results directory for everything the harness writes; harness/lib/paths.sh
// exports TEST_RESULTS_DIR, and the runners pass it through.
const summaryPath = process.env.COVERAGE_SUMMARY_FILE
  || path.join(process.env.TEST_RESULTS_DIR || 'results', 'coverage-summary.txt');
fs.mkdirSync(path.dirname(summaryPath), { recursive: true });
fs.writeFileSync(summaryPath, summaryContent);
console.log(`Summary written to: ${summaryPath}`);
console.log('');

// Exit code
if (coverage.failed > 0) {
  console.log('Exit code: 1 (tests failed)');
  process.exit(1);
} else if (coverage.executed === 0) {
  console.log('Exit code: 2 (no tests executed)');
  process.exit(2);
} else {
  console.log('Exit code: 0 (all tests passed)');
  process.exit(0);
}