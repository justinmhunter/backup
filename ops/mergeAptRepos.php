<?

$sourceRepo = "/var/spool/apt-mirror-live/mirror/";
$destRepo = "/var/spool/apt-mirror-froz/mirror/";

/*
this script will:
- enumerate newly created dirs that aren't present in the dest dir
- enumerate each dir that's different btw src and dest
- prompt user for each dir to be rsync'ed
- rsync the two
*/

function listDirs($dir,$launchpad=null) {
  global $dirs;
  if ($handle = opendir($dir)) {
    while (false !== ($repo = readdir($handle))) {
      if(preg_match('/^ppa\.launchpad\.net$/', $repo)) {
        listDirs($dir.$repo."/",'launchpad');
      }
      if(!preg_match('/^\.{1,2}$/',$repo) && is_dir($dir.$repo)) {
        if(!preg_match('/archive\.ubuntu\.com|^ppa\.launchpad\.net$/',$repo)) { 
          $repo = $launchpad ? 'ppa.launchpad.net/'.$repo : $repo;
          array_push($dirs,$repo);
        }
      }
    }
    closedir($handle);
  }
  sort($dirs);
  return $dirs;
}

function listPackages($repo, $dirs) {
  $packages = array();
  foreach($dirs as $dir) {
    $fileNames = array();
    $packages[$dir] = array();
    $it = new RecursiveDirectoryIterator($repo.$dir);
    foreach(new RecursiveIteratorIterator($it) as $file) {
      if(preg_match('/\.deb$|\.rpm$/',$file)){
        array_push($fileNames,$file->getFilename());
      }
    }
    sort($fileNames);
    $packages[$dir] = $fileNames;
  }
  return $packages; 
}

$dirs = array(); // doing this 2x in order to get proper Launchpad packages/dirs in place.
$sourceDirs = listDirs($sourceRepo);
$dirs = array(); // i know. ugly.
$destDirs = listDirs($destRepo);
$dirDiffs = array_diff($sourceDirs,$destDirs);
sort($dirDiffs);

$dirsToRsync = array();
if(!empty($dirDiffs)) {
  echo "The following dir(s) are present in the live repo ($sourceRepo) but not in the frozen repo ($destRepo):\n";
  foreach($dirDiffs as $i => $dir) {
    $i++;
    while(1){
      echo $i . ") $dir - rsync with $destRepo? [ y/n ] ";
      $resp = fgets(STDIN);
      if(preg_match('/y/i',$resp)) {
        array_push($dirsToRsync, $dir);
        echo "INFO: Setting $dir to rsync\n";
        break;
      } elseif(preg_match('/n/i',$resp)) {
        echo "INFO: Ignoring $dir from rsync\n";
        break;
      } else {
        echo "ERR: I don't know that response.\n";
      }
    }
  }
}

$sourcePackages = listPackages($sourceRepo, $sourceDirs);
$destPackages = listPackages($destRepo, $destDirs);
foreach($sourcePackages as $repo => $arr) {
  if(in_array("$repo",$dirDiffs)){ continue; }
  echo "Checking $repo .. ";
  sleep(2);
  $packageDiffs = array_diff($sourcePackages[$repo], $destPackages[$repo]);
  sort($packageDiffs);
  if(count($packageDiffs) > 0) {
    while(1){
      echo "There are " . count($packageDiffs) . " different packages in ${repo}.\n";
      echo "Rsync ${repo} with ${destRepo}? [ s(how)/y/n ] ";
      $resp = fgets(STDIN);
      if(preg_match('/y/i',$resp)) {
        echo "INFO: Setting ${repo} to rsync\n";
        array_push($dirsToRsync, $repo);
        break;
      }elseif(preg_match('/s/i',$resp)) {
        print_r($packageDiffs);
        echo "Checking $repo .. ";
      }elseif(preg_match('/n/i',$resp)) {
        echo "INFO: Ignoring ${repo} from rsync\n";
        break;
      } else { 
        echo "ERR: I don't know that response.";
      }
    }
  } else {
    echo "No difference in packages.\n";
  }
}

echo "\n";

if(empty($dirsToRsync)) {
  echo "INFO: No directories selected to rsync. Exiting.\n";
  exit;
}else{
  print_r($dirsToRsync);
  echo "INFO: The above directories will be rsync'ed in 10 secs (CTRL+C to cancel)";
  for($i=0;$i<10;$i++){
    sleep(1);
    echo ".";
  }
  echo "\n";
  foreach($dirsToRsync as $dir) {
    system("rsync -a /var/spool/apt-mirror-live/mirror/${dir}/ /var/spool/apt-mirror-froz/mirror/${dir}/");
    if(preg_match('/^local$/',$dir)) {
      system("cd /var/spool/apt-mirror-froz/mirror/local/amd64; dpkg-scanpackages . | gzip -9c > /var/spool/apt-mirror-froz/mirror/local/amd64/Packages.gz");
    }else{
      system("rsync -a /var/spool/apt-mirror-live/skel/${dir}/ /var/spool/apt-mirror-froz/skel/${dir}/");
    }
  }
}

echo "Complete. Exiting.\n";
exit;
