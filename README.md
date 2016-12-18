# Replay-Mongo
Mongo support for the Replay framework

It is convenient to store the documents for a replay system in Mongo databases.

# Capabilities Provided

## Replay::Role::Mongo

This is the more abstract role to be consumed by other modules that are going to talk to Mongo dbs inside of Replay.

### provides these interfaces

$self->db - the mongo database handle
$self->collection($idkey) - the collection that would be used for data pointed to by that $idkey
$self->cubby($idkey) - the document identifier that would be used for data pointed by that $idkey

### requires implementation of this interface

 _build_dbname - return what you want to call this database based on configuration
 _build_dbauthdb - return the name of the database used for authentication
 _build_dbuser - return the username configured
 _build_dbpass - return the password configured

## Replay::StorageEngine::Mongo

this is the portion of the configuration of Replay that chooses to use the Mongo storage engine, and defines
the user and password used for connecting to it.  Use the Mongo mode of the Storage Engine and this package
will be utilized.  Include your database access information as per internal implementation.

```perl
  Replay->new (
     StorageEngine => {
         Mode      => 'Mongo',
         User => 'replayuser',
         Pass => 'replaypass',
      },
  );
```

This implimentation stores all of the data in one database per Replay instance.  Each database has a collection for each version of
each rule for which information is being stored.  Each collection has documents identified by their key 'idkey' in the root of the
document.

## Replay::ReportEngine::Mongo

Report output can be stored in the mongo system too.  By selecting mode Mongo and having the report engine selector
select the instance in question.

```perl
  Replay->new (
     Defaults => { ReportEngine => 'MyMongoReports' }, # Which instance identifier is default?
     ReportEngines => [ { 
         Name => 'MyMongoReports',    # this is our report instance identifier
         Mode => 'Mongo',             # Selects Replay::ReportEngine::Mongo
         User => 'replayuser',       
         Pass => 'replaypass',
      } ] 
    );
``` 

# How to get a Mongo up and running for Replay from an empty unauthed state;
 - create a myUserAdmin
```javascript
use admin
db.createUser( {
      user: 'myUserAdmin',
      pwd: 'abc123',
      roles: [ { role: 'userAdminAnyDatabase', db: 'admin' } ] } )
```
- enable user auth on the db and restart it (auth=true in mongodb.conf)
- log in as that user
```javascript
mongo -u myUserAdmin -p abc123 admin
```
- create the replay user
```javascript
db.createUser( { user: 'replayuser', pwd: 'replaypass', roles: [ { role: 
   'dbAdminAnyDatabase' ,db: 'admin' }, { role: 'readWriteAnyDatabase', db:
   'admin' } ] } )
```
