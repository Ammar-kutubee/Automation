const { execSync } = require('child_process');
const readline = require('readline');

const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout
});

function runCommand(command) {
  try {
    console.log(`Running: ${command}`);
    execSync(command, { stdio: 'inherit' });
  } catch (error) {
    console.error(`Error running command: ${error.message}`);
    process.exit(1);
  }
}

function askQuestion(query) {
  return new Promise(resolve => rl.question(query, resolve));
}

(async function() {
  try {
    // Ask for branch names and version number
    const developBranch = await askQuestion('Enter the develop branch name: ');
    const mainBranch = await askQuestion('Enter the main branch name: ');
    const version = await askQuestion('Enter the version number: ');
    const releaseBranch = `release/${version}`;

    // Checkout develop branch
    runCommand(`git checkout ${developBranch}`);

    // Pull the latest changes
    runCommand(`git pull origin ${developBranch}`);

    // Checkout new release branch
    runCommand(`git checkout -b ${releaseBranch}`);

    // Checkout main branch
    runCommand(`git checkout ${mainBranch}`);

    // Merge release branch into main --no-ff
    runCommand(`git merge ${releaseBranch} --no-ff`);

    // Tag the release branch
    runCommand(`git tag -a ${version} -m "Release ${version}"`);

    // Push changes
    runCommand(`git push origin ${mainBranch}`);
    runCommand(`git push origin ${version}`);

    console.log('Release process completed successfully.');

  } finally {
    rl.close();
  }
})();
