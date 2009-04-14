# ${license-info}
# ${developer-info}
# ${author-info}
# ${build-info}
#

package NCM::Component::pbsserver;
  
use strict;
use NCM::Component;
use vars qw(@ISA $EC);
@ISA = qw(NCM::Component);
$EC=LC::Exception::Context->new->will_store_all;
use NCM::Check;

use EDG::WP4::CCM::Element;

use File::Copy;
use File::Path;

local(*DTA);


##########################################################################
sub Configure($$@) {
##########################################################################
    
    my ($self, $config) = @_;

    # Define paths for convenience and retrieve configuration 
    my $base = "/software/components/pbsserver";
    my $pbsserver_config = $config->getElement($base)->getTree();

    # Save the date.
    my $date = localtime();

    # Retrieve location for pbs working directory and ensure it exists.
    my $pbsroot = "/var/spool/pbs";
    if ( $pbsserver_config->{pbsroot} ) {
      $pbsroot = $pbsserver_config->{pbsroot};
    }
    mkpath($pbsroot, 0, 0755) unless (-e $pbsroot);
    if (! -d $pbsroot) {
      $self->Fail("Can't create directory: $pbsroot");
      return 1;
    }

    # Retrieve the contents of the envrionment file and update if necessary/ 
    if ( $pbsserver_config->{env} ) {
      my $fname = "$pbsroot/pbs_environment";
      $self->info("Checking environment file ($fname)...");
      my $contents = "#\n# File generated by ncm-pbsserver. DO NOT EDIT\n#\n";
      for my $name (keys(%{$pbsserver_config->{env}})) {
        $contents .= "$name=".$pbsserver_config->{env}->{$name}."\n";
      }
      my $result = LC::Check::file( $fname,
                                    backup => ".old",
                                    contents => $contents,
                                    );
      if ( $result < 0 ) {
        $self->error("Error updating $fname");
      } elsif ( $result > 0 ) { 
        $self->log("$fname updated. Restarting pbs_server...");
        if (system('/sbin/service pbs_server restart')) {
          $self->error('pbs_server init.d restart failed: '. $?);
        }
      }      
    }


    # Update the submit filter.  This is used only by the qsub
    # command, so the server doesn't need to be restarted for changes
    # here.
    # Be very careful, the file will NOT work with embedded comments.
    if ( $pbsserver_config->{submitfilter} ) {
      $self->info("Checking submission filter...");
      my $fname = "$pbsroot/torque.cfg";
      my $contents = "SUBMITFILTER $pbsroot/submit_filter\n";
      my $result = LC::Check::file($fname,
                                   backup => ".old",
                                   contents => $contents,
                                  );
      if ( $result < 0 ) {
        $self->error("Error updating $fname");
      } elsif ( $result > 0 ) { 
        $self->log("$fname updated");
      }

      $contents = $pbsserver_config->{submitfilter};
      $fname = "$pbsroot/submit_filter";
      $result = LC::Check::file($fname,
                                backup => ".old",
                                contents => $contents,
                               );
      if ( $result < 0 ) {
        $self->error("Error updating $fname");
      } elsif ( $result > 0 ) { 
        $self->log("$fname updated");
      }
      chmod 0755, "$fname";


    # Ensure that any existing filter is removed.  Since the
    # submitfilter is the only parameter in torque.cfg, this file
    # can be removed as well.
    } else {
      $self->info("Removing submission filter...");
      unlink "$pbsroot/torque.cfg" if (-e "$pbsroot/torque.cfg");
      unlink "$pbsroot/submit_filter" if (-e "$pbsroot/submit_filter");
    }


    # Determine the location of the pbs commands. 
    my $binpath = "/usr/bin";
    if ( $pbsserver_config->{binpath} ) {
      $binpath = $pbsserver_config->{binpath};
    }
    my $qmgr = "$binpath/qmgr";
    my $pbsnodes = "$binpath/pbsnodes";
    if (! (-x $qmgr)) {
      $self->error("$qmgr isn't executable");
      return 1;
    }
    if (! (-x $pbsnodes)) {
      $self->error("$pbsnodes isn't executable");
      return 1;
    }

    # Command to retrieve the server state from torque.
    my $qmgr_state = "$qmgr -c \"print server\"";

    # Wait a bit for the server to become active in case it has been restarted.
    # Check every 30s after the first try until it comes up; try for up to  
    # 5 minutes.
    $self->info("Retrieving current configuration...");
    my $remaining = 10;
    sleep 5;
    my @current_config = qx/$qmgr_state/;
    while ( $? && ($remaining > 0) ) {
      $self->log("waiting 30s for qmgr to respond; $remaining tries remaining");
      $remaining--;
      sleep 30;
      @current_config = qx/$qmgr_state/;
    }
    if ( $? ) {
      $self->error("qmgr is not responding; aborting configuration");
      return 1;
    }

    # Slurp the existing server and queue information into a set of hashes. 
    my %existingsatt;
    my %existingqueues;
    for (@current_config) {
      chomp;
      if (m/set server (\w+)/) {
        # Mark the server attribute as set.
        $existingsatt{$1} = 1;

      } elsif (m/create queue ([\w\.\_]+)/) {
        # Create a hash for the queue.
        $existingqueues{$1} = {};

      } elsif (m/set queue ([\w\.\_]+)\s+([\w\.]+)/) {
        # Mark the attribute as set for the given queue. 
        my $queue = $1;
        my $name = $2;
        my $href = $existingqueues{$queue};
        $href->{$name} = 1;
      }
    }

    ## server configuration
    ## $serverbase --+ 
    ##               +--manualconfig : boolean
    ##               +--attlist ? nlist
    ## If manualconfig is false, remove any existing config parameter not part of the configuration.
    my %definedsatt;
    if ( $pbsserver_config->{server} ) {
      $self->info("Updating server attributes...");
      if ( $pbsserver_config->{server}->{attlist} ) {
        my $server_attlist = $pbsserver_config->{server}->{attlist};
        for my $serveratt (keys(%{$server_attlist})) {
          $definedsatt{$serveratt} = 1;
          $self->runCommand($qmgr, "set server $serveratt = ".$server_attlist->{$serveratt});          
        }
      }

      # Removing non-defined server attributes if manualconfig is set to false
      if ( defined($pbsserver_config->{server}->{manualconfig}) && 
           !$pbsserver_config->{server}->{manualconfig} ) {
        $self->debug(1,"Removing server attributes not part of the configuration (manualconfig=false)");
        foreach (keys %existingsatt) {
          unless ( defined($definedsatt{$_}) ||
                   ($_ eq "pbs_version") ||
                   ($_ eq "next_job_number") ) {
            $self->runCommand($qmgr, "unset server $_");
          }
        }
      }      
    }
    

    ## queue configuration
    ## $queuebase --+ 
    ##              +--manualconfig : boolean
    ##              +--queuelist--+ ? nlist
    ##                            +--manualconfig : boolean
    ##                            +--attlist ? nlist
    ## If manualconfig is false, remove any existing config parameter not part of the configuration.

    my %definedqueues;
    if ( $pbsserver_config->{queue} ) {
      $self->info("Updating queue list and queue attributes...");
      if ( $pbsserver_config->{queue}->{queuelist} ) {
        my $queuelist = $pbsserver_config->{queue}->{queuelist};
        for my $queue (keys(%{$queuelist})) {
          $definedqueues{$queue} = 1;
          if (!$existingqueues{$queue}) {
              $self->runCommand($qmgr, "create queue $queue");
          }

          my %definedqatt;
          if ( $queuelist->{$queue}->{attlist} ) {
            my $queue_attlist = $queuelist->{$queue}->{attlist};
            for my $queueatt (keys(%{$queue_attlist})) {
              $definedqatt{$queueatt} = 1;
              # Ensure queue is enabled and started after the configuration has been done
              if (($queueatt ne "enabled") && ($queueatt ne "started")) {
                $self->runCommand($qmgr, "set queue $queue $queueatt = ".$queue_attlist->{$queueatt});
              }
            }
            for my $queueatt ('enabled', 'started') {
              if ( $definedqatt{$queueatt} ) {
                $self->runCommand($qmgr, "set queue $queue $queueatt = ".$queue_attlist->{$queueatt});
              }              
            }
          }

          # Removing non-defined queue attributes if manualconfig is set to false
          if ( defined($queuelist->{$queue}->{manualconfig}) && 
               !$queuelist->{$queue}->{manualconfig} ) {
            $self->debug(1,"Removing queue $queue attributes not part of the configuration (manualconfig=false)");
            foreach (keys %{$existingqueues{$queue}}) {
              $self->runCommand($qmgr, "unset queue $queue $_") unless (defined($definedqatt{$_}));
            }
          }
        }      
      }

      # Delete existing queues not part of the configuration if manualconfig is set to 
      if ( defined($pbsserver_config->{queue}->{manualconfig}) && 
           !$pbsserver_config->{queue}->{manualconfig}  ) {
        foreach (keys %existingqueues) {
          unless (defined($definedqueues{$_})) {
            $self->info("Removing queue $_...");
            $self->runCommand($qmgr, "delete queue $_");            
          }
        }
      }
    }


    # This slurps the pbsnodes output into a hash of hashes.  This
    # avoids having to rerun the command. 
    my %existingnodes;
    my $lastnode = '';
    if (-e "$pbsroot/server_priv/nodes" && -s "$pbsroot/server_priv/nodes") {
      my @node_list = qx/$pbsnodes -a/;
      if ($?) {
        $self->error("error running $pbsnodes");
        return 1;
      }
      for (@node_list) {
        chomp;
        if (m/(^[\w\d\.-]+)\s*$/) {    
          # Start of a section with node name.
          $lastnode = $1;
          $existingnodes{$lastnode} = {};
    
        } elsif (m/^\s*(\w+)\s*=\s*(.*)/) {  
          # This is an attribute.  Attach it to last node.
          my $name = $1;
          my $value = $2;
          if ($lastnode and not (($name eq "status") ||($name eq "jobs"))) {
            my $href = $existingnodes{$lastnode};
            $href->{$name} = $value;
          }
        }
      }
    }

    ## node configuration 
    ## $nodebase--+ 
    ##            +--manualconfig : boolean
    ##            +--nodelist--+ ? nlist
    ##                         +--manualconfig : boolean
    ##                         +--attlist ? nlist

    my %definednodes;
    if ( $pbsserver_config->{node} ) {
      $self->info("Updating WN list and WN attributes...");
      if ( $pbsserver_config->{node}->{nodelist} ) {
        my $nodelist = $pbsserver_config->{node}->{nodelist};
        for my $node (keys(%{$nodelist})) {
          $definednodes{$node} = 1;
          $self->runCommand($qmgr, "create node $node") unless (defined($existingnodes{$node}));

          # Retrieve node attributes and properties.
          # properties is a comma separated list.
          my %definednatt;
          my %existingnatt;
          my %defprops;
          if (defined($existingnodes{$node})) {
              my $href = $existingnodes{$node};
              %existingnatt = %$href;
          }
          if (defined($existingnatt{properties})) {
            my @props = split /,/, $existingnatt{properties};
            foreach my $p (@props) {
              $defprops{$p} = 1;
            } 
          }
    
          if ( $nodelist->{$node}->{attlist} ) {
            my $node_attlist = $nodelist->{$node}->{attlist};
            for my $nodeatt (keys(%{$node_attlist})) {
              if ($nodeatt eq "properties") {
                my @newprops = split /,/, $node_attlist->{$nodeatt};
                foreach my $p (@newprops) {
                  if (defined($defprops{$p})) {
                    delete $defprops{$p};
                  } else {
                    $self->runCommand($qmgr, "set node $node $nodeatt += $p");
                  }
                }
              } elsif ($nodeatt ne "status") {
                $definednatt{$nodeatt} = 1;
                $self->runCommand($qmgr, "set node $node $nodeatt = ".$node_attlist->{$nodeatt});
              }
            }
          }

          # Removing non-defined node attributes if manualconfig is set to false
          if ( $nodelist->{$node}->{manualconfig} && 
               !$nodelist->{$node}->{manualconfig} ) {
            $self->debug(1,"Removing node $node attributes not part of the configuration (manualconfig=false)");
            # First delete properties not part of the configuration
            foreach my $p (keys %defprops) {
              $self->runCommand($qmgr, "set node $node properties -= $p");
            }
            # Delete attributes not part of the configuration, preserving special attributes
            # like state, status or ntype.
            foreach (keys %existingnatt) {
              if (!defined($definednatt{$_}) && 
                  ($_ ne "ntype") && 
                  ($_ ne "state") &&
                  ($_ ne "properties") &&
                  ($_ ne "status")) {
                $self->runCommand($qmgr, "unset node $node $_");
              }
            }
          }
        }      
      }

      # Delete existing nodes not part of the configuration if manualconfig is set to false
      if ( defined($pbsserver_config->{node}->{manualconfig}) && 
           !$pbsserver_config->{node}->{manualconfig} ) {
        foreach (keys %existingnodes) {
          unless (defined($definednodes{$_})) {
            $self->info("Removing node $_...");
            $self->runCommand($qmgr, "delete node $_");            
          }
        }
      }
    }

    
    return 1;
}


# Convenience routine to run a command and print out the result.
sub runCommand {
    my ($self, $qmgr, $cmd) = @_;
    my $s = `$qmgr -c \"$cmd\"`;
    if ($?) {
      $self->error("ERROR (" . ($? >> 8)  . "): $cmd");
    } else {
      $self->log("OK: $cmd");
    }
}

1;      # Required for PERL modules
