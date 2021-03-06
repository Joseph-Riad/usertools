#!/usr/bin/perl
#===============================================================================
#
#         FILE: useradd
#
#        USAGE: see man 8 useradd
#
#  DESCRIPTION: Implementation of useradd(8) interface to automatically create
#               a user principal in the default Kerberos realm + add user info
#               to an LDAP database
#
#      OPTIONS: Most of the options listed in  man 8 useradd are supported. 
#               The additional option ( --unsupported ) returns a list of 
#               unsupported options from the useradd(8) man page.
# REQUIREMENTS: Authen::Krb5::Easy, Authen::Krb5::Admin, 
#               Authen::SASL, Authen::SASL::XS, Net::LDAP
#               Devel::CheckLib (required by Authen::SASL::XS but for some reason
#               not pulled in automatically by the cpan client)
#         BUGS: ---
#        NOTES: ---
#       AUTHOR: Joseph Riad (joseph.samy.albert@gmail.com), 
#      COMPANY: 
#      VERSION: 1.0
#      CREATED: 07/14/2014 06:16:32 PM
#     REVISION: ---
#===============================================================================

use strict;
use warnings;
use Getopt::Long;
use File::Spec;
use File::Path;
use File::Find;
use File::Copy::Recursive qw(rcopy);
use Tie::File;
use Time::Local;


# Bail out early unless root is running the script:
die "Sorry, this script must be run as root!\n" unless ( $> == 0 && $< == 0 && $( == 0 && $) == 0 );

#>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
# Initialization
#<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

Getopt::Long::Configure( qw(
	no_ignore_case
	bundling
	permute
    )
);


my $useradd_file   = '/etc/default/useradd';
my $logindefs_file = '/etc/login.defs';
my $nslcd_file     = '/etc/nslcd.conf';
our %options;      # Command line options
my $gidNumber;    # Primary GID number (needs to be visible to perform_additional_actions)

# Initialize %options
for my $option (qw(
                    b base-dir
                    c comment
                    d home
                    D defaults
                    e expiredate
                    f inactive
                    g gid
                    G groups
                    h help
                    k skel
                    K key
                    l no-log-init
                    m create-home
                    M 
                    N no-user-group 
                    o non-unique 
                    p password 
                    r system 
                    R root 
                    s shell 
                    u uid 
                    U user-group 
                    Z selinux-user
					policy
                    )){

						$options{$option}= undef
}
# Synonymous options:
our %synonyms = (
  'b'  =>  'base-dir'      ,
  'c'  =>  'comment'       ,
  'd'  =>  'home'          ,
  'D'  =>  'defaults'      ,
  'e'  =>  'expiredate'    ,
  'f'  =>  'inactive'      ,
  'g'  =>  'gid'           ,
  'G'  =>  'groups'        ,
  'h'  =>  'help'          ,
  'k'  =>  'skel'          ,
  'K'  =>  'key'           ,
  'l'  =>  'no-log-init'   ,
  'm'  =>  'create-home'   ,
  'N'  =>  'no-user-group' ,
  'o'  =>  'non-unique'    ,
  'p'  =>  'password'      ,
  'r'  =>  'system'        ,
  'R'  =>  'root'          ,
  's'  =>  'shell'         ,
  'u'  =>  'uid'           ,
  'U'  =>  'user-group'    ,
  'Z'  =>  'selinux-user'  ,
);

# To be filled with file contents later:
our %config_files = ( 
	$useradd_file => undef,
	$logindefs_file => undef,
);
use UtilitySubs; # Subroutines common to all user tools

#>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
# Main program
#<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

&install_synonyms;        # Install option handlers for long options
&parse_command_line;      # Parse the command line arguments
my $login = shift @ARGV;  # The log in name is the last thing left after
                          # the command line is parsed.
&validate_login;
&obtain_option_defaults;  # Obtain defaults for options not specified.
                          # Default behaviors are documented in useradd(8)

&obtain_krb_creds;
my $ldap_bind = &bind_to_ldap_server;
&add_ldap_entry;
my $krb5_admin = &build_kadm_object;
&add_kerberos_principal;
&perform_additional_actions; # Such as creating the home directory, copying the skeleton,...
&destroy_krb_creds;

#>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
# Subroutines
#<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

#-------------------------------------------------------------------------------
#
# parse_command_line
# Calls GetOptions to parse command line options and call the appropriate
# handle for each option.
#
#-------------------------------------------------------------------------------

sub parse_command_line{
	GetOptions(
                'b=s'             =>  \&handle_option,
                'base-dir=s'      =>  \&handle_option,
                'c=s'             =>  \&handle_option,
                'comment=s'       =>  \&handle_option,
                'd=s'             =>  \&handle_option,
                'home=s'          =>  \&handle_option,
                'D'               =>  \&handle_option,
                'defaults'        =>  \&handle_option,
                'e=s'             =>  \&handle_option,
                'expiredate=s'    =>  \&handle_option,
                'f=i'             =>  \&handle_option,
                'inactive=i'      =>  \&handle_option,
                'g=s'             =>  \&handle_option,
                'gid=s'           =>  \&handle_option,
                'G=s@'            =>  \&handle_option,
                'groups=s@'       =>  \&handle_option,
                'h'               =>  \&handle_option,
                'help'            =>  \&handle_option,
                'k=s'             =>  \&handle_option,
                'skel=s'          =>  \&handle_option,
                'K=s%'            =>  \&handle_option,
                'key=s%'          =>  \&handle_option,
                'l'               =>  \&handle_option,
                'no-log-init'     =>  \&handle_option,
                'm'               =>  \&handle_option,
                'create-home'     =>  \&handle_option,
                'M'               =>  \&handle_option,
                'N'               =>  \&handle_option,
                'no-user-group'   =>  \&handle_option,
                'o'               =>  \&handle_option,
                'non-unique'      =>  \&handle_option,
                'p=s'             =>  \&handle_option,
                'password=s'      =>  \&handle_option,
                'r'               =>  \&handle_option,
                'system'          =>  \&handle_option,
                'R=s'             =>  \&handle_option,
                'root=s'          =>  \&handle_option,
                's=s'             =>  \&handle_option,
                'shell=s'         =>  \&handle_option,
                'u=i'             =>  \&handle_option,
                'uid=i'           =>  \&handle_option,
                'U'               =>  \&handle_option,
                'user-group'      =>  \&handle_option,
                'Z=s'             =>  \&handle_option,
                'selinux-user=s'  =>  \&handle_option,
                'unsupported'     =>  \&handle_option,
				'keytab=s'        =>  \&handle_option,
				'principal=s'     =>  \&handle_option,
				'realm=s'         =>  \&handle_option,
				'server=s'        =>  \&handle_option,
				'base=s'          =>  \&handle_option,
				'policy=s'        =>  \&handle_option,
		);
		if ($options{D}){
			my $modify_defaults = grep { $_ ne 'D' && defined $options{$_} } sort keys %options; 
			if ( ! $modify_defaults ){ # We'll just list the defaults
				$options{N} = 1; # Ensure we get the default group ID when no login is supplied
				&default_g; print "GROUP=$options{g}\n";
				&default_b; print "HOME=$options{b}\n";
				&default_f; print "INACTIVE=$options{f}\n";
				&default_e; print "EXPIRE=$options{e}\n";
				&default_s; print "SHELL=$options{s}\n";
				&default_k; print "SKEL=$options{k}\n";
				&parse_config($useradd_file);
				my $create_mail_spool = $config_files{$useradd_file}{CREATE_MAIL_SPOOL} // 'no';
				print "CREATE_MAIL_SPOOL=$create_mail_spool\n";
				exit 0;
			}
			else{ # We need to modify the defaults:
				tie my @useradd,'Tie::File',$useradd_file;
				map{
				    /^\s*#?\s*HOME/ && s/(?<==)\s*.*/$options{b}/ && s/^#\s*// if defined $options{b};
				    /^\s*#?\s*EXPIRE/ && s/(?<==)\s*.*/$options{e}/ && s/^#\s*// if defined $options{e};
				    /^\s*#?\s*INACTIVE/ && s/(?<==)\s*.*/$options{f}/ && s/^#\s*// if defined $options{f};
				    /^\s*#?\s*GROUP/ && s/(?<==)\s*.*/$options{g}/ && s/^#\s*// if defined $options{g};
				    /^\s*#?\s*SHELL/ && s/(?<==)\s*.*/$options{s}/ && s/^#\s*// if defined $options{s};
				} @useradd;
				untie @useradd;
				exit 0;
			}
		}
		if( $options{m} and $options{M} ){
			&handle_h(undef,undef); # Print a usage message and exit
		}
		if( not $options{m} and defined $options{b} and ! -d $options{b} ) 
		  { die "The base directory $options{b} does not exist and -m is not set. Aborting!\n"}
}

#-------------------------------------------------------------------------------
#
# Option handlers
# Subroutines returning $_[1] simply leave their option's value unchanged
# Subroutines returning 1 simply assert the presence of a flag
#
#-------------------------------------------------------------------------------


sub handle_b ($;$) { $_[1] }
sub handle_c ($;$) { $_[1] }
sub handle_d ($;$) { $_[1] }
sub handle_D ($;$) {   1   }
sub handle_e ($;$) { 
	my ($o,$v) = @_;
	if($v =~ /([0-9]{4})-([0-9]{2})-([0-9]{2})/){ # Match YYYY-MM-DD
		my ($y,$m,$d) = ($1,$2,$3);
		die "Invalid expiry date ($v) specified!\n"
		if(
			    $m <= 1 
			 || $m <= 12 
			 || ( $d > 29 && $m == 2)
			 || ( $d > 30 && grep { $m == $_ } (4,6,9,11) )
		);
				
	} else { warn "Expiry date $v is not in YYYY-MM-DD format!\n";exit 1 }
	$v
}
sub handle_f ($;$) { $_[1] }

sub handle_g ($;$) { 
	my ($o,$v) = @_;
	if ( $v =~ /^\s*[0-9]+\s*$/ )  { warn "The group with GID $v does not exist!\n" and exit 1 unless getgrgid($v)} 
	else                           { warn "The group named $v does not exist!\n" and exit 1 unless getgrnam($v)}
	$v
}

sub handle_G ($;$) { 
	my ($o,$v) = @_;
	my @groups = split /,/,join ',',$v;
	for (@groups){
		handle_g undef,$_;
	}
	\@groups
}

sub handle_h ($;$) { 
  my $script_name = $0;
  $script_name =~ s{.*/}{}; # Keep the basename only
  my $help_header =<<EOI;
Usage: (copied from man 8 $script_name) 
   $script_name [options] LOGIN
   $script_name -D
   $script_name -D [options]
Options: (ported from $script_name)
EOI
  my %help_text = (
    b => ', --base-dir BASE_DIR       base directory for the home directory of the
                                new account',
    c => ', --comment COMMENT         GECOS field of the new account',
    d => ', --home-dir HOME_DIR       home directory of the new account',
    D => ', --defaults                print or change default useradd configuration',
    e => ', --expiredate EXPIRE_DATE  expiration date of the new account',
    f => ', --inactive INACTIVE       password inactivity period of the new account',
    g => ', --gid GROUP               name or ID of the primary group of the new
                                account',
    G => ', --groups GROUPS           list of supplementary groups of the new
                                account',
    h => ', --help                    display this help message and exit',
    k => ', --skel SKEL_DIR           use this alternative skeleton directory',
    K => ', --key KEY=VALUE           override /etc/login.defs defaults',
    l => ', --no-log-init             do not add the user to the lastlog and
                                faillog databases',
    m => ', --create-home             create the user\'s home directory',
    M => ', --no-create-home          do not create the user\'s home directory',
    N => ', --no-user-group           do not create a group with the same name as
                                the user',
    o => ', --non-unique              allow to create users with duplicate
                                (non-unique) UID',
    p => ', --password PASSWORD       cleartext password of the new account
	                            this arugment is mandatory,',
    r => ', --system                  create a system account',
    R => ', --root CHROOT_DIR         directory to chroot into',
    s => ', --shell SHELL             login shell of the new account',
    u => ', --uid UID                 user ID of the new account',
    U => ', --user-group              create a group with the same name as the user',
    Z => ', --selinux-user SEUSER     use a specific SEUSER for the SELinux user mapping',
  );
  my $help_body = '';
  for my $option (grep { length($_) == 1 && supported $_} sort { lc $a cmp lc $b } keys %options){
  	$help_body .= "  -$option$help_text{$option}\n";
  }
  $help_body .= &add_common_help_message; # Additional options for LDAP and Kerberos
  $help_body .= <<EOI;
  --policy                      Kerberos policy to be used for creating principals. Defaults
                                to no policy if not supplied
EOI
  warn $help_header . $help_body;
  exit 0;
}

sub handle_k ($;$) { $_[1] }
sub handle_m ($;$) {   1   }
sub handle_M ($;$) {   1   }
sub handle_N ($;$) {   1   }
sub handle_p ($;$) {
	my ($o,$v) = @_;
	unless( defined $v){
		warn "Empty passwords are not allowed!\n";
		exit 1
	}
	$v
}

sub handle_s ($;$) { $_[1] }
sub handle_u ($;$) {
	my ($o,$v) = @_;
	if( getpwuid $v ){
		warn "UID $v already exists!\n";
		exit 1
	}
	$v
}
sub handle_U ($;$) {   1   }

sub handle_policy    { $_[1] }

#>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
# Default option handlers
#<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

sub default_b {
	my $file = $useradd_file;
	parse_config $file;
	$options{b} = $config_files{$file}{HOME} // '/home';
}

sub default_d { 
	if(not defined $options{b}){ default_b }
	$options{d} = File::Spec->catdir($options{b} , $login)
}

sub default_e {
	my $file = $useradd_file;
	parse_config $file;
	$options{e} = $config_files{$file}{EXPIRE} // '';
}

sub default_f {
	my $file = $useradd_file;
	parse_config $file;
	$options{f} = $config_files{$file}{INACTIVE} // -1;
}

sub default_g {
	my $file1 = $logindefs_file;
	my $file2 = $useradd_file;
	parse_config $file1;
	parse_config $file2;
	if(  defined $options{U} 
		 || defined $options{'user-group'}){

		 $options{g} = $login;
	}
	elsif( 
		  defined $options{N}
		  || defined $options{'no-user-group'}){

		  $options{g} = $config_files{$file2}{GROUP} // 100
	}
	elsif($config_files{$file1}{USERGROUPS_ENAB} eq 'yes'){
		  $options{g} = $login;
	}
	else { $options{g} = $config_files{$file2}{GROUP} // 100 }
}

sub default_k {
	my $file = $useradd_file;
	parse_config $file;
	$options{k} = $config_files{$file}{SKEL} // '/etc/skel'
}

sub default_p {
	die "You must supply a password!\n";
}

sub default_s {
	my $file = $useradd_file;
	parse_config $file;
	$options{s} = $config_files{$file}{SHELL} // ''
}

sub default_u { 
	my $uid = &get_newid('user',$logindefs_file);
	die "Failed to obtain a new UID!\n" unless defined $uid;
	$options{u} = $uid
}


#-------------------------------------------------------------------------------
#
# add_kerberos_principal
#
#-------------------------------------------------------------------------------

sub add_kerberos_principal {
	my @pw_policies = $krb5_admin->get_policies;
	if (defined $options{policy}){
	    die "Policy $options{policy} undefined!\n" 
	      unless grep { $_ eq $options{policy} } @pw_policies;
	}
	my $principal = new Authen::Krb5::Admin::Principal;
	my $princ = Authen::Krb5::parse_name($login) or die Authen::Krb5::error;
	$principal->principal($princ);
	my $expiry_date;
	my ($year,$month,$day) = split /-/, $options{e},3;
	$month-- if defined $month;
	my ($hours,$minutes,$seconds) = (11,59,59); # Account expires at midnight!
	if(defined $year and defined $month and defined $day) {
		$expiry_date = timelocal($seconds,$minutes,$hours,$day,$month,$year);
		$principal->princ_expire_time($expiry_date);
	}
	# Set principal attributes from options:
	$principal->attributes(         # Documented in the kadmin(1) man page
		KRB5_KDB_REQUIRES_PRE_AUTH  # So that authentication may succeed the first time
	   |KRB5_KDB_REQUIRES_PWCHANGE  # So that the password we set in the clear isn't an issue
	);
	if(defined $options{policy}){
	    $principal->aux_attributes(KADM5_POLICY);
	    $principal->policy($options{policy});
    }
	if(defined $expiry_date){ $principal->princ_expire_time($expiry_date)}
    my $success = $krb5_admin->create_principal($principal,$options{p});
	die "Failed to create Kerberos principal for user $login: ".Authen::Krb5::Admin::error
	  unless $success;
}

#-------------------------------------------------------------------------------
#
# perform_additional_actions
#
#-------------------------------------------------------------------------------

sub perform_additional_actions { 
	if($options{m}){
		mkpath($options{d},{ mode => 0700}) or die "Failed to create home directory for user $login. $!\n";
		# Copy the skeleton directory's files:
		for(<$options{k}/* $options{k}/.*>){
			my $basename = s{.*/}{}r;
			next if $basename eq '.' or $basename eq '..';
			rcopy($_,$options{d}) or die "Failed to copy skeleton directory for user $login. $!\n";
		}
		my $uid = $options{u};
        # Make the newly copied files owned by the user:
		chown $uid,$gidNumber,find(sub{ $File::Find::name },$options{d}) or die "Failed to chown home directory for user $login. $!\n"; 
	}
}

#-------------------------------------------------------------------------------
#
# add_ldap_entry
#
#-------------------------------------------------------------------------------

sub add_ldap_entry {
		my $cn = $login;
		my $sn = $login;
		my $gecos = $login;
		if(defined $options{c} and $options{c} ne ''){
			$gecos = $options{c};
			$cn = (split /,/,$options{c})[0];
			$sn = (split / /,$cn        )[0];
		}

		my @groups = (&getgname($options{g}));
		if(defined $options{G} and $options{G} ne ''){
		  push @groups, map {&getgname($_)}(@{$options{G}});
	    }
		my $primary_group = shift @groups;
		if( $primary_group eq $login and not &group_exists($primary_group) ) {
			# We need to add an entry for the user group:
			$gidNumber = &get_newid('group',$logindefs_file);
			die "Failed to obtain a new GID!\n" unless defined $gidNumber;
			my $result = $ldap_bind->add("cn=$login,$options{base}",
				attrs => [
				       objectClass => [ 'posixGroup','top'],
				       cn          => $login,
					   gidNumber   => $gidNumber,
				]
			);
			$result->code && die "Failed to add entry for group $login ".$result->error."\n";

		}
		if(not defined $gidNumber){ $gidNumber = &getgid($primary_group) }
		my $result = $ldap_bind->add("uid=$login,$options{base}",
		             attrs => [
						 uid              => $login,
						 cn               => $cn,
						 sn               => $sn,
						 objectClass      => [ 'posixAccount','top','inetOrgPerson' ],
						 uidNumber        => $options{u},
						 gidNumber        => $gidNumber,
						 homeDirectory    => $options{d},
						 gecos            => $gecos,
						 loginShell       => $options{s},
						 #mail             => , #TODO: Implement later
						 #jpegPhoto        => ,
					 ]
				 );
		$result->code && die "Failed to add entry for user $login: ".$result->error."\n";
		
		# Now make the user member of any additional groups specified:
		for( @groups ){
			my $result = $ldap_bind->modify("cn=$_,$options{base}",
				add => [
					memberUid => $login,
				]
			);
			$result->code && die "Failed to add user $login to group $_ ".$result->error."\n";
		}

}

#-------------------------------------------------------------------------------
#
# validate_login
# Dies if the supplied login violates Debian's constraints on user names
# outlined in useradd(8)
#
#-------------------------------------------------------------------------------

sub validate_login{
	parse_config $nslcd_file;
	my $valid_name_regex = $config_files{$nslcd_file}{validnames} // qr{^[a-z0-9._\@\$][a-z0-9._\@$ \\~-]*[a-z0-9._\@$~-]*$}i;
	for($login){
		die "The user name $_ is invalid. See man 8 useradd and man 5 nslcd.conf for information on constraints.\n"
		  if 
			    m{^(?:-|\+|~)}
			or  m{(?::|,|\s|/)}
			or  length > 32
		    or not m{$valid_name_regex}
	}
}
