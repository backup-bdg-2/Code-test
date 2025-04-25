#!/bin/bash
set -eo pipefail

# This script generates a GitHub Actions workflow summary from build error reports
# It's designed to be called from the auto-fix-build-errors workflow

echo "📝 Generating build error report summary..."

# Create the summary markdown file
echo "## 📊 Build Error Analysis Report" > $GITHUB_STEP_SUMMARY
echo "" >> $GITHUB_STEP_SUMMARY
echo "A detailed analysis of the build errors has been generated." >> $GITHUB_STEP_SUMMARY
echo "" >> $GITHUB_STEP_SUMMARY

# Extract summary information from the JSON report
if [ -f "build_error_report.json" ]; then
  ERROR_COUNT=$(grep -o '"error_count":[0-9]*' build_error_report.json | cut -d ":" -f2)
  WARNING_COUNT=$(grep -o '"warning_count":[0-9]*' build_error_report.json | cut -d ":" -f2)
  
  echo "### Summary" >> $GITHUB_STEP_SUMMARY
  echo "" >> $GITHUB_STEP_SUMMARY
  echo "* 🛑 **Errors**: ${ERROR_COUNT:-0}" >> $GITHUB_STEP_SUMMARY
  echo "* ⚠️ **Warnings**: ${WARNING_COUNT:-0}" >> $GITHUB_STEP_SUMMARY
  echo "" >> $GITHUB_STEP_SUMMARY
  
  # Extract error types if available
  ERROR_TYPES_JSON=$(grep -o '"error_types":{[
^
}]*}' build_error_report.json)
  if [ -n "$ERROR_TYPES_JSON" ]; then
    echo "### Error Types" >> $GITHUB_STEP_SUMMARY
    echo "" >> $GITHUB_STEP_SUMMARY
    echo "```" >> $GITHUB_STEP_SUMMARY
    # Format the JSON for better readability
    echo "$ERROR_TYPES_JSON" | sed 's/"error_types"://' | sed 's/{//' | sed 's/}//' | sed 's/,/\n/g' | sed 's/"//g' | sed 's/:/: /g' >> $GITHUB_STEP_SUMMARY
    echo "```" >> $GITHUB_STEP_SUMMARY
    echo "" >> $GITHUB_STEP_SUMMARY
  fi
else
  echo "### Summary" >> $GITHUB_STEP_SUMMARY
  echo "" >> $GITHUB_STEP_SUMMARY
  echo "No detailed error report was generated." >> $GITHUB_STEP_SUMMARY
  echo "" >> $GITHUB_STEP_SUMMARY
fi

# Include top issues from the text report
if [ -f "build_error_report.txt" ]; then
  echo "### Common Issues" >> $GITHUB_STEP_SUMMARY
  echo "" >> $GITHUB_STEP_SUMMARY
  
  # Extract top error types
  ERROR_TYPES_SECTION=$(grep -A 10 "ERROR TYPES:" build_error_report.txt)
  if [ -n "$ERROR_TYPES_SECTION" ]; then
    echo "```" >> $GITHUB_STEP_SUMMARY
    echo "$ERROR_TYPES_SECTION" >> $GITHUB_STEP_SUMMARY
    echo "```" >> $GITHUB_STEP_SUMMARY
    echo "" >> $GITHUB_STEP_SUMMARY
  fi
  
  # Extract a few example errors for quick reference
  echo "### Example Errors" >> $GITHUB_STEP_SUMMARY
  echo "" >> $GITHUB_STEP_SUMMARY
  echo "```" >> $GITHUB_STEP_SUMMARY
  grep -A 2 "ERROR:" build_error_report.txt | head -n 9 >> $GITHUB_STEP_SUMMARY
  echo "```" >> $GITHUB_STEP_SUMMARY
  echo "" >> $GITHUB_STEP_SUMMARY
fi

echo "📦 Artifact Information" >> $GITHUB_STEP_SUMMARY
echo "" >> $GITHUB_STEP_SUMMARY
echo "A detailed HTML report has been uploaded as an artifact." >> $GITHUB_STEP_SUMMARY
echo "Download it from the workflow run page for a more comprehensive analysis." >> $GITHUB_STEP_SUMMARY

echo "✅ Report summary generation complete"

# Output success so CI knows we completed successfully
exit 0
