#!/bin/bash
set -eo pipefail

# This script creates a PR comment with build error analysis
# It requires a GitHub token and PR number

echo "💬 Creating PR comment with build error analysis..."

# Validate input parameters
PR_NUMBER="$1"
if [ -z "$PR_NUMBER" ]; then
  echo "::error::No PR number provided"
  exit 1
fi

if [ ! -f "build_error_report.json" ]; then
  echo "::error::No build error report found"
  exit 1
fi

# Create a temporary directory for the Node.js script
mkdir -p temp
cat > temp/create-comment.js << 'EOL'
const fs = require('fs');

async function createComment() {
  try {
    // Parse inputs
    const prNumber = process.env.PR_NUMBER;
    const token = process.env.GITHUB_TOKEN;
    const [owner, repo] = process.env.GITHUB_REPOSITORY.split('/');
    
    if (!prNumber || !token || !owner || !repo) {
      console.error('Missing required environment variables');
      process.exit(1);
    }
    
    console.log(`Creating comment on PR #${prNumber} in ${owner}/${repo}`);
    
    // Create the Octokit client
    const { Octokit } = require('@octokit/rest');
    const octokit = new Octokit({ auth: token });
    
    // Read the error report data
    if (!fs.existsSync('build_error_report.json')) {
      console.error('Error report JSON file not found');
      process.exit(1);
    }
    
    const reportData = JSON.parse(fs.readFileSync('build_error_report.json', 'utf8'));
    const errorCount = reportData.summary.error_count;
    const warningCount = reportData.summary.warning_count;
    
    // Format error types for display
    let errorTypesList = '';
    if (reportData.summary.error_types) {
      errorTypesList = Object.entries(reportData.summary.error_types)
        .map(([type, count]) => `${type}: ${count}`)
        .join('\n');
    }
    
    // Create the comment body
    const body = `## 🔍 Build Error Analysis Report

This PR contains:
- 🛑 **${errorCount} errors**
- ⚠️ **${warningCount} warnings**

<details>
<summary>Click to see error type breakdown</summary>

\`\`\`
${errorTypesList}
\`\`\`
</details>

Please check the workflow run for the full HTML report with error details and suggestions for fixing them.
`;
    
    // Create the comment
    await octokit.issues.createComment({
      owner,
      repo,
      issue_number: prNumber,
      body
    });
    
    console.log(`Successfully created comment on PR #${prNumber}`);
    process.exit(0);
  } catch (error) {
    console.error('Error creating PR comment:', error.message);
    process.exit(1);
  }
}

createComment();
EOL

# Install octokit if not already installed
npm install @octokit/rest

# Set environment variables and run the script
export PR_NUMBER="$PR_NUMBER"
export GITHUB_TOKEN="${GITHUB_TOKEN}"

echo "Running comment creation script..."
node temp/create-comment.js

# Clean up temporary files
rm -rf temp

echo "✅ PR comment creation complete"
