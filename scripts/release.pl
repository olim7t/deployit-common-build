#!/usr/bin/perl

# PRE-REQUISITES:
# - brew install jsawk

#
# TO DO:
# - distinguish between releasing maintenance vs master
# - distinguish between releasing a single project (e.g. plugin) and releasing deployit
# - double check that common build is on same branch before update and before building
# - tee build output to console or log file so you can see what is happening

$DEBUG = 0;
$VERBOSE = 1;
$DRYRUN = 0;

#
# Checkout the master branch (or maintenance branch):
# $ git checkout master
# Make sure you have no outstanding work:
# $ git status
# Make sure your local copy of the development branch is up to date:
# $ git pull --rebase
# Set the version number in the main build.gradle file to the version you want to release
# $ vi build.gradle
# Build the release and upload the archives to nexus. If you are building a maintenance release from master remember to specify the desired maintenance branch of the common build.
# $ gradle clean build uploadArchives uploadDocumentation -PcommonBuild=<branch>
# (warning)TIP On the Deployit project, make sure the integration tests run by including the 'build' target.
# When doing a Deployit release, upload the distribution ZIP files from the deployit project. Please skip this step if you are releasing a licensed plugin.
# $ gradle uploadDeployitDist -PcommonBuild=<branch>
# Tagging & Updating Dependencies
# Commit the changed version number
# $ git commit -a -m "Released version X.Y.Z"
# Make a tag for the release
# $ git tag PROJECT-X.Y.Z
# Set the version number in the main build.gradle file to the next snapshot version
# $ vi build.gradle
# Commit the changed version number
# $ git commit -a -m "Set development version to X.Y.Z-SNAPSHOT"
# Push the updated branch with tags back to the origin:
# $ git push --tags origin master

sub waitKey {
	print "Waiting for key\n";
	$dummy = <STDIN>;
}

sub execute {
	my $cmd = shift;
	my $message = shift;
	my $output = executeAndReturn($cmd, $message);
	
	if ($? != 0) {
		die "$message: $!";
	}
	return $output;
}

sub executeAndReturn {
	my $cmd = shift;
	my $message = shift;
	
	if($DEBUG == 1 || $VERBOSE == 1) {
		print "\n- running '$cmd'\n";
	}
	
	if ($DEBUG != 1) {
		return `$cmd 2>&1`;
	}
}

sub checkOutstandingWork {
	print("Checking for outstanding work... ");
	
	my $output = `git status | grep 'working directory clean'`;
	if(length($output) == 0) {
		print "git reports there is outstanding work, quitting...\n";
		exit 1;
	}
	print("done.\n");
}

sub updateLocalRepo {
	print("Ensuring local repo is up to date... ");
	
	execute("git pull --rebase", "Failed to update local repository");
	print("done.\n");
}

sub updateFile {
	my $filename = shift;
	my $string = shift;
	my $replacement = shift;
	my $match = 0;
	
	open(IN, "< $filename") || die "Can't open $filename";
	my @lines = <IN>;
	close(IN);
	
	foreach $line (@lines) {
		if($line =~ /$string/) {
			$match++;
		}
		$line =~ s/$string/$replacement/g;
	}
	
	my $output = $filename;
	$output = "$filename.new" if($DEBUG == 1);
	open(OUT, "> $output") || die "Can't open $output";
	foreach $line (@lines) {
		print OUT $line;
	}
	close(OUT);
	
	if ($DEBUG == 1) {
		print "\n - wrote $filename.new\n"
	}
	return $match;
}

sub setReleaseVersion {
	my $version = shift;
	my $release = shift;

	print("Setting release version to $release... ");
	updateFile("build.gradle", $version, $release);
	print("done.\n");
}

sub buildReleaseVersion {
	my $project = shift;

	print("Building project... ");

	my $command = "gradle clean build uploadArchives uploadDocumentation";
	if ($project eq "deployit") {
		$command = "gradle clean build uploadArchives uploadDocumentation uploadDeployitDist";
	}

	if ($DRYRUN == 1) {
		$command = "gradle clean build";
	}
	
	my $log = executeAndReturn($command);
	if($? != 0) {
		print "\nError building project, build log:\n";
		print $log;
		exit 1;
	}
	print("done.\n");
}

sub commitAndTagRelease {
	my $project = shift;
	my $release = shift;
	print("Committing and tagging released version... ");
	waitKey();
	execute("git commit -a -m 'Released $project-$release'", "Failed to commit updated build.gradle");
	execute("git tag '$project-$release'", "Failed to tag project");
	
	print("done.\n");
}

sub setAndCommitDevelopmentVersion {
	my $release = shift;
	my $developmentVersion = shift;
	print("Setting and committing development version... ");
	
	updateFile("build.gradle", $release, $developmentVersion);
	waitKey();
	execute("git commit -a -m 'Setting development version $developmentVersion'", "Failed to commit updated build.gradle");
	print("done.\n");
}

sub pushChanges {
	my $branch = shift;
	print("Pushing changes... ");
	execute("git push --tags origin $branch", "Failed to push changes");
	print("done.\n");
}

# TODO double check on same branch
sub updateDependenciesIfNeeded {
	my $project = shift;
	my $releaseVersion = shift;

    #apiVersion = '4.0.0-alpha-9'
    #engineVersion = '4.0.0-alpha-15'
    #bundledPluginsVersion = '4.0.0-alpha-1'
    #cloudPackVersion = '3.9.2'
    #licenseDatabaseVersion = '1.0.8'
	
	my %projectToVersion = ( 
		"plugin-api" => "apiVersion",
		"bundled-plugins" => "bundledPluginsVersion",
		"engine" => "engineVersion",
		"cloud-plugin" => "cloudPackVersion",
		"overthere" => "overthereVersion"
		);

	if(exists($projectToVersion{$project})) {
		print("Updating common dependencies... ");
		
		my $dependency = $projectToVersion{$project};
		print "Project $project is represented by dependency $dependency" if($DEBUG == 1);
		
		execute("cd ../deployit-common-build && git pull --rebase", "Failed to update deployit-common-build");
		updateFile("../deployit-common-build/dependencies.gradle", "$dependency = '[^']+'", "$dependency = '$releaseVersion'");
		waitKey();

		execute("cd ../deployit-common-build && git commit -a -m '$project $releaseVersion'", "Failed to commit updated dependencies.gradle");
		execute("cd ../deployit-common-build && git tag '$project-$releaseVersion'", "Failed to tag dependencies.gradle");
		execute("cd ../deployit-common-build && git push --tags origin $branch", "Failed to push changes to deployit-common-build");
		
		print("Done.\n");
	} else {
		print("No update to common dependencies needed.\n");
	}
}

sub createMaintenanceBranchIfNeeded {
	my $releaseVersion = shift;
	if ($releaseVersion =~ /\.0$/) {
		$releaseVersion =~ /^([0-9]\.[0-9])/;
		$maintenanceBranch = "$1.x-maintenance";
		print("Creating maintenance branch $maintenanceBranch... ");
		execute("git branch $maintenanceBranch", "Failed to create maintenance branch");
		execute("git push origin $maintenanceBranch", "Failed to push maintenance branch");
		print("done.\n");
	}
}

sub prepareReleaseNotes {
  
  my $project = shift;
  my $branch = shift;
  my $version = shift;
  
  print("Querying JIRA for release notes for $project on $branch\n");
  
  print("Jira username: ");
  chomp($username=<STDIN>);
  system('stty','-echo');
  print("Jira password: ");
  chomp($password=<STDIN>);
  system('stty','echo');
  print("\n");
  
  my $jsAwkScript = "'
  out(\"*** Version ${version}\")
  var issuesByType = _.reduce(this.issues, function(memo, i) {
    if (i.fields.issuetype.name == \"Bug\") {
      memo.Bugs.push(i) 
    } else {
      memo.Improvements.push(i)
    }
    return memo
  }, {\"Bugs\": [], \"Improvements\": []})
  _.each(issuesByType, function(issues, type) {
    if (issues.length == 0) return
    out(\"** \" + type)
    _.each(issues, function(i) {
      out(\"    * \" + i.key + \" \" + i.fields.summary)
    })
  })
  '";
  
  my $escapedBranch = $branch;
  $escapedBranch =~ s/\./\\u002e/g;
  my $releaseNotes = execute("curl -s -u $username:$password -X GET -H 'Content-Type: application/json' https://xebialabs.atlassian.net/rest/api/latest/search?jql=fixVersion='$escapedBranch'+AND+status='Release\\u0020Ready'+AND+component=$project | jsawk -n $jsAwkScript", "Failed to request release notes. Incorrect credentials?");
  
  print("-----------------------------------------------------------------------------------------  \n");
  print($releaseNotes);
  print("-----------------------------------------------------------------------------------------  \n");  
  print("Are you OK with adding this to release-notes.txt? [y] y/n? ");
  chomp($answer=<STDIN>);
  if ($answer == 'y' || $answer == 'yes' || $answer == '') {
    $releaseNotes =~ s/'/\\'/g;
    my $head = execute("head -n 1 release-notes.txt");
    $head =~ s/'/\\'/g;
    my $tail = execute("tail -n +2 release-notes.txt");
    $tail =~ s/'/\\'/g;
    
    execute("echo '$head' > release-notes.txt.new; echo '$releaseNotes' >> release-notes.txt.new; echo '$tail' >> release-notes.txt.new;");
    
    print "Thanks for trusting me! Updated release-notes.txt \n";
    
    if ($DRYRUN == 0) {
      execute('mv release-notes.txt.new release-notes.txt')
    }
    
  } else {
    print "Then update release notes manually. Press enter when done. \n";
    chomp();
  }
  
  
  print("Completed preparing release notes. \n");
  
}

##############
# MAIN

`pwd` =~ /\/([^\/]+)$/m;
$project = $1;
chomp($project);

$releaseScope = "project";

# Not sure why but this doesn't work!
#$releaseScope = "product" if (! -f ".gitignore");

if ($releaseScope eq "product") {
	die "Detected product release which is currently not supported, exiting...";
}

`git branch -l` =~ /\*\s+(.+)$/m;
$branch = $1;

$releaseType = "major";
$releaseType = "minor" if ($branch =~ /maintenance/);

print "\n";
print "Releasing project $project, git branch $branch\n";
print "Release scope: $releaseScope\n";
print "Release type: $releaseType\n";
print "(running in debug mode)\n\n" if ($DEBUG == 1);

`GREP_OPTIONS='' grep version build.gradle` =~ /^\s*version\s*=\s*['"](.+)['"]/m;
$version = $1;
print "Current version: $version\n";

$version =~ /(.*)-SNAPSHOT/;
$releaseVersion = $1;
print "Release version: $releaseVersion\n";

$releaseVersion =~ /^([0-9])\.([0-9])(\.([0-9]+))?$/;
$developmentVersion = "$1" . "." . "$2" . "." . (int($4) + 1) . "-SNAPSHOT";
print "Development version: $developmentVersion\n";

print "\n";

prepareReleaseNotes($project, $branch, $releaseVersion);

checkOutstandingWork();
updateLocalRepo();
setReleaseVersion($version, $releaseVersion);
buildReleaseVersion($project, $releaseVersion);
commitAndTagRelease($project, $releaseVersion);
setAndCommitDevelopmentVersion($releaseVersion, $developmentVersion);
pushChanges($branch);
updateDependenciesIfNeeded($project, $releaseVersion);
#createMaintenanceBranchIfNeeded($releaseVersion);
