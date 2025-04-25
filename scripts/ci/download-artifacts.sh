#!/bin/bash
set -eo pipefail

# This script downloads and extracts artifacts from a failed workflow run
# It's designed to be called from the auto-fix-build-errors workflow

echo "📥 Starting artifact download process..."

# Validate required inputs
WORKFLOW_RUN_ID="$1"
if [ -z "$WORKFLOW_RUN_ID" ]; then
  echo "::error::No workflow run ID provided"
  exit 1
fi

# Create a directory for the Node.js script
mkdir -p temp
cat > temp/download-artifacts.js << 'EOL'
const fs = require('fs');
const path = require('path');

async function downloadArtifacts() {
  try {
    // Parse inputs
    const workflowRunId = process.env.WORKFLOW_RUN_ID;
    const token = process.env.GITHUB_TOKEN;
    const [owner, repo] = process.env.GITHUB_REPOSITORY.split('/');
    
    if (!workflowRunId || !token || !owner || !repo) {
      console.error('Missing required environment variables');
      process.exit(1);
    }
    
    console.log(`Downloading artifacts for workflow run ${workflowRunId} in ${owner}/${repo}`);
    
    // Create the Octokit client
    const { Octokit } = require('@octokit/rest');
    const octokit = new Octokit({ auth: token });
    
    // List artifacts
    const { data: artifactsList } = await octokit.actions.listWorkflowRunArtifacts({
      owner,
      repo,
      run_id: workflowRunId
    });
    
    console.log(`Found ${artifactsList.artifacts.length} artifacts`);
    
    // Find the build log artifact
    const buildLog = artifactsList.artifacts.find(artifact => 
      artifact.name === "ipa-files" || 
      artifact.name.includes("build") || 
      artifact.name.includes("log")
    );
    
    if (!buildLog) {
      console.log("No build log artifacts found");
      process.exit(0);
    }
    
    console.log(`Found build log artifact: ${buildLog.name} (${buildLog.id})`);
    
    // Download the artifact
    const download = await octokit.actions.downloadArtifact({
      owner,
      repo,
      artifact_id: buildLog.id,
      archive_format: 'zip'
    });
    
    // Save the zip file
    fs.writeFileSync('artifact.zip', Buffer.from(download.data));
    console.log('Artifact downloaded successfully to artifact.zip');
    
    // Create a manifest file with artifact details
    fs.writeFileSync('artifact-manifest.json', JSON.stringify({
      artifact_id: buildLog.id,
      artifact_name: buildLog.name,
      workflow_run_id: workflowRunId
    }, null, 2));
    
    console.log('Successfully created artifact manifest');
    process.exit(0);
  } catch (error) {
    console.error('Error downloading artifacts:', error.message);
    process.exit(1);
  }
}

downloadArtifacts();
EOL

# Install octokit
npm install @octokit/rest

# Set environment variables and run the script
export WORKFLOW_RUN_ID="$WORKFLOW_RUN_ID"
export GITHUB_TOKEN="${GITHUB_TOKEN}"

echo "Running download script..."
node temp/download-artifacts.js

# Extract the artifacts
echo "Extracting artifacts..."
mkdir -p artifact-contents
unzip -o artifact.zip -d artifact-contents || {
  echo "::warning::Failed to extract artifacts, possibly empty or corrupt"
  ls -la
  exit 0
}

# List extracted contents
echo "Extracted artifact contents:"
ls -la artifact-contents

# Look for build logs - try multiple common names
if [ -f "artifact-contents/build_log.txt" ]; then
  echo "Build log found, copying for analysis..."
  cp artifact-contents/build_log.txt ./
elif [ -f "artifact-contents/buildlog.txt" ]; then
  echo "Build log found as buildlog.txt, copying for analysis..."
  cp artifact-contents/buildlog.txt ./build_log.txt
elif [ -f "artifact-contents/xcodebuild.log" ]; then
  echo "Build log found as xcodebuild.log, copying for analysis..."
  cp artifact-contents/xcodebuild.log ./build_log.txt
else
  # If we can't find a specific log file, look for any text file
  TEXT_FILE=$(find artifact-contents -name "*.txt" -or -name "*.log" | head -n 1)
  if [ -n "$TEXT_FILE" ]; then
    echo "Using $TEXT_FILE as build log..."
    cp "$TEXT_FILE" ./build_log.txt
  else
    echo "::warning::No build log found in artifacts"
    # Create an empty log file to prevent errors in subsequent steps
    echo "No build log found. This is a placeholder." > build_log.txt
  fi
fi

# Clean up temporary files
rm -rf temp

echo "✅ Artifact processing complete"
