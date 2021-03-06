# MAPI implementation for R

PROTOCOL_v8 <- 8
PROTOCOL_v9 <- 9
MAX_PACKET_SIZE <- 8192

HASH_ALGOS <- c("md5", "sha1", "crc32", "sha256", "sha512")

MSG_REDIRECT <- "^"
MSG_MESSAGE  <- "!"
MSG_PROMPT   <- ""
MSG_QUERY    <- "&"
MSG_SCHEMA_HEADER <- "%"
MSG_ASYNC_REPLY <- "_"


Q_TABLE       <- 1 
Q_UPDATE      <- 2 
Q_CREATE      <- 3
Q_TRANSACTION <- 4
Q_PREPARE     <- 5
Q_BLOCK       <- 6


REPLY_SIZE    <- 100 # Apparently, -1 means unlimited, but we will start with a small result set. 
# The entire set might never be fetch()'ed after all!

# .mapiRead and .mapiWrite implement MonetDB's MAPI protocol. It works as follows: 
# Ontop of the socket stream, blocks are being sent. Each block has a two-byte header. 
# MAPI protocol messages are sent as one or more blocks in both directions.
# The block header contains two pieces of information: 1) the amount of bytes in the block, 
# 2) a flag indicating whether the block is the final block of a message.

# this is a combination of read and write to synchronize access to the socket. 
# otherwise, we could have issues with finalizers

.mapiRequest <- function(conObj, msg, async=FALSE) {
  # call finalizers on disused objects. At least avoids concurrent access to socket.
  #gc()
  
  if (!identical(class(conObj)[[1]], "MonetDBConnection"))
    stop("I can only be called with a MonetDBConnection as parameter, not a socket.")
  
  # ugly effect of finalizers, sometimes, single-threaded R can get concurrent calls to this method.
  if (conObj@connenv$lock > 0) {
    if (async) {
      if (getOption("monetdb.debug.mapi", F)) message("II: Attempted parallel access to socket. ",
                                                      "Deferred query '", msg, "'")
      conObj@connenv$deferred <- c(conObj@connenv$deferred, msg)
      return("_")
    } else {
      stop("II: Attempted parallel access to socket. Use only dbSendUpdateAsync() from finalizers.")
    }
  }
  
  # add exit handler that will clean up the socket and release the lock.
  # just in case someone (Anthony!) uses ESC or CTRL-C while running some long running query.
  on.exit(.mapiCleanup(conObj), add=TRUE)
  
  # prevent other calls to .mapiRequest while we are doing something on this connection.
  conObj@connenv$lock <- 1
  
  # send payload and read response		
 
  .mapiWrite(conObj@socket, msg)
  resp <- .mapiRead(conObj@socket)
  
  # get deferred statements from deferred list and execute
  while (length(conObj@connenv$deferred) > 0) {
    # take element, execute, check response for prompt
    dmesg <- conObj@connenv$deferred[[1]]
    conObj@connenv$deferred[[1]] <- NULL
    .mapiWrite(conObj@socket, dmesg)
    dresp <- .mapiParseResponse(.mapiRead(conObj@socket))
    if (dresp$type == MSG_MESSAGE) {
      conObj@connenv$lock <- 0
      warning(paste("II: Failed to execute deferred statement '", dmesg, "'. Server said: '", 
                    dresp$message, "'"))
    }
  }	
  # release lock
  conObj@connenv$lock <- 0
  
  return(resp)
}


.mapiConnect <- function(host, port, timeout) {
  if (getOption("monetdb.clib", FALSE)) {
    return(.Call("mapiConnect", host, port, timeout, PACKAGE=C_LIBRARY))
  } else {
    return(socketConnection(host = host, port = port, blocking = TRUE, open="r+b", timeout = timeout))
  }
}

.mapiDisconnect <- function(socket) {
  if (getOption("monetdb.clib", FALSE)) {
    .Call("mapiDisconnect", socket, PACKAGE=C_LIBRARY)
  } else {
      # close, don't care about the errors...
      tryCatch(close(socket), error=function(e){}, warning=function(w){})
  }
}

.mapiCleanup <- function(conObj) {
  if (conObj@connenv$lock > 0) {
    if (getOption("monetdb.debug.query", F)) message("II: Interrupted query execution.")
    conObj@connenv$lock <- 0
  }
}

.mapiRead <- function(con) {
  if (getOption("monetdb.clib", FALSE)) {
    if (!identical(class(con)[[1]], "externalptr"))
      stop("I can only be called with a MonetDB connection object as parameter.")
    respstr <- .Call("mapiRead", con, PACKAGE=C_LIBRARY)
    if (getOption("monetdb.debug.mapi", F)) {
      dstr <- respstr
      if (nchar(dstr) > 300) {
        dstr <- paste0(substring(dstr, 1, 200), "...", substring(dstr, nchar(dstr)-100, nchar(dstr))) 
      } 
      message("RX: '", dstr, "'")
    }
    return(respstr)
  } else { 
    # R implementation
    if (!identical(class(con)[[1]], "sockconn"))
      stop("I can only be called with a MonetDB connection object as parameter.")
    resp <- list()
    repeat {
      unpacked <- readBin(con,"integer",n=1,size=2,signed=FALSE,endian="little")
      
      if (length(unpacked) == 0) {
        stop("Empty response from MonetDB server, probably a timeout. You can increase the time to wait for responses with the 'timeout' parameter to 'dbConnect()'.")
      }
      
      length <- bitwShiftR(unpacked,1)
      final  <- bitwAnd(unpacked,1)
          
      if (length == 0) break
      resp <- c(resp,readChar(con, length, useBytes = TRUE))    
      if (final == 1) break
    }
    if (getOption("monetdb.debug.mapi", F)) cat(paste("RX: '",substring(paste0(resp,collapse=""),1,200),"'\n",sep=""))
    return(paste0("",resp,collapse=""))
  }
}

.mapiWrite <- function(con, msg) {
  if (getOption("monetdb.clib", FALSE)) {
    # C implementation
    if (!identical(class(con)[[1]], "externalptr"))
        stop("I can only be called with a MonetDB connection object as parameter.")

    if (getOption("monetdb.debug.mapi", F))  message("TX: '", msg, "'")
    .Call("mapiWrite", con, msg, PACKAGE=C_LIBRARY)

  } else { 
    # R implementation
    if (!identical(class(con)[[1]], "sockconn"))
      stop("I can only be called with a MonetDB connection object as parameter.")
    final <- FALSE
    pos <- 0
    if (getOption("monetdb.debug.mapi", F))  message("TX: '",msg,"'\n",sep="")
    while (!final) {    
      req <- substring(msg,pos+1,min(MAX_PACKET_SIZE, nchar(msg))+pos)
      bytes <- nchar(req)
      pos <- pos + bytes
      final <- max(nchar(msg) - pos,0) == 0            
      header <- as.integer(bitwOr(bitwShiftL(bytes,1),as.numeric(final)))
      writeBin(header, con, 2,endian="little")
      writeChar(req,con,bytes,useBytes=TRUE,eos=NULL)
    }
    flush(con)
  }
  return(NULL)
}

.mapiCleanup <- function(conObj) {
  if (conObj@connenv$lock > 0) {
    if (getOption("monetdb.debug.query", F)) message("II: Interrupted query execution.")
    conObj@connenv$lock <- 0
  }
}

.mapiLongInt <- function(someint) {
  stopifnot(length(someint) == 1)
  formatC(someint, format="d")
}

# determines and partially parses the answer from the server in response to a query
.mapiParseResponse <- function(response) {
  #lines <- .Call("mapiSplitLines", response, PACKAGE="MonetDB.R")
  lines <- strsplit(response, "\n", fixed=TRUE, useBytes=TRUE)[[1]]
  if (length(lines) < 1) {
    stop("Invalid response from server. Try re-connecting.")
  }
  typeLine <- lines[[1]]
  resKey <- substring(typeLine, 1, 1)
  
  if (resKey == MSG_ASYNC_REPLY) {
    return(list(type=MSG_ASYNC_REPLY))
  }
  if (resKey == MSG_MESSAGE) {
    return(list(type=MSG_MESSAGE, message=typeLine))
  }
  if (resKey == MSG_QUERY) {
    typeKey <- as.integer(substring(typeLine, 2, 2))
    env <- new.env(parent=emptyenv())
    
    # Query results
    if (typeKey == Q_TABLE || typeKey == Q_PREPARE) {
      header <- .mapiParseHeader(lines[1])
      if (getOption("monetdb.debug.query", F)) message("QQ: Query result for query ", header$id, 
                                                       " with ", header$rows, " rows and ", header$cols, " cols, ", header$index, " rows.")
      
      env$type	<- Q_TABLE
      env$id		<- header$id
      env$rows	<- header$rows
      env$cols	<- header$cols
      env$index	<- header$index
      env$tables	<- .mapiParseTableHeader(lines[2])
      env$names	<- .mapiParseTableHeader(lines[3])
      env$types	<- env$dbtypes <- toupper(.mapiParseTableHeader(lines[4]))
      env$lengths	<- .mapiParseTableHeader(lines[5])
      
      if (env$rows > 0) env$tuples <- lines[6:length(lines)]
      
      stopifnot(length(env$tuples) == header$index)
      return(env)
    }
    # Continuation of Q_TABLE without headers describing table structure
    if (typeKey == Q_BLOCK) {
      header <- .mapiParseHeader(lines[1], TRUE)
      if (getOption("monetdb.debug.query", F)) message("QQ: Continuation for query ", header$id, 
                                                       " with ", header$rows, " rows and ", header$cols, " cols, index ", header$inde, ".")
      
      env$type	<- Q_BLOCK
      env$id		<- header$id
      env$rows	<- header$rows
      env$cols	<- header$cols
      env$index	<- header$index
      env$tuples <- lines[2:length(lines)]
      
      stopifnot(length(env$tuples) == header$rows)
      
      return(env)
    }
    
    # Result of db-altering query
    if (typeKey == Q_UPDATE || typeKey == Q_CREATE) {
      header <- .mapiParseHeader(lines[1], TRUE)
      
      env$type	<- Q_UPDATE
      env$id		<- header$id
      
      return(env)			
    }
    
    if (typeKey == Q_TRANSACTION) {
      env$type	<- Q_UPDATE
      # no need to check the returned values, as there is none. If we get no error, all is well.
      return(env)
    }
    
  }
}

.mapiParseHeader <- function(line, stupidInverseColsRows=FALSE) {
  tableinfo <- strsplit(line, " ", fixed=TRUE, useBytes=TRUE)
  tableinfo <- tableinfo[[1]]
  
  id    <- as.numeric(tableinfo[2])
  if (!stupidInverseColsRows) {
    rows  <- as.numeric(tableinfo[3])
    cols  <- as.numeric(tableinfo[4])
  }
  else {
    rows  <- as.numeric(tableinfo[4])
    cols  <- as.numeric(tableinfo[3])
  }
  index <- as.numeric(tableinfo[5])
  
  return(list(id=id, rows=rows, cols=cols, index=index))
}

.mapiParseTableHeader <- function(line) {
  first <- strsplit(substr(line, 3, nchar(line)), " #", fixed=TRUE, useBytes=TRUE)
  second <- strsplit(first[[1]][1], ",\t", fixed=TRUE, useBytes=TRUE)
  second[[1]]
}

# authenticates the client against the MonetDB server. This is the first thing that happens
# on each connection. The server starts by sending a challenge, to which we respond by
# hashing our login information using the server-requested hashing algorithm and its salt.

.mapiAuthenticate <- function(con, dbname, user="monetdb", password="monetdb", 
                               endhashfunc="sha512", language="sql") {
  
  endhashfunc <- tolower(endhashfunc)
  # read challenge from server, it looks like this
  # oRzY7XZr1EfNWETqU6b2:merovingian:9:RIPEMD160, SHA256, SHA1, MD5:LIT:SHA512:
  # salt:protocol:protocolversion:hashfunctions:endianness:hashrequested
  challenge <- .mapiRead(con)
  credentials <- strsplit(challenge, ":", fixed=TRUE)
  
  algos <- strsplit(credentials[[1]][4], ", ", fixed=TRUE)
  protocolVersion <- credentials[[1]][3]
  
  if (protocolVersion != PROTOCOL_v9) {
    stop("Protocol versions != 9 NOT SUPPORTED")
  }
  
  pwhashfunc <- tolower(credentials[[1]][6])
  salt <- credentials[[1]][1]
  
  if (!(endhashfunc %in% HASH_ALGOS)) {
    stop("Server-requested end hash function ", endhashfunc, " is not available")
  }
  
  if (!(pwhashfunc %in% HASH_ALGOS)) {
    stop("Server-requested password hash function ", pwhashfunc, " is not available")
  }
  
  # We first hash the password with the server-requested hash function 
  # (SHA512 in the example above).
  # then, we hash that hash together with the server-provided salt using 
  # a hash function from the list provided by the server. 
  # By default, we use SHA512 for both.
  hashsum <- digest(paste0(digest(password, algo=pwhashfunc, serialize=FALSE), salt), 
                    algo=endhashfunc, serialize=FALSE)	
  
  # we respond to the authentication challeng with something like
  # LIT:monetdb:{SHA512}eec43c24242[...]cc33147:sql:acs
  # endianness:username:passwordhash:language:databasename
  authString <- paste0("LIT:", user, ":{", toupper(endhashfunc), "}", hashsum, ":", language, ":", 
                       dbname, ":")
  .mapiWrite(con, authString)
  authResponse <- .mapiRead(con)
  respKey <- substring(authResponse, 1, 1)
  
  if (respKey != MSG_PROMPT) {
    if (respKey == MSG_REDIRECT) {
      redirects <- strsplit(authResponse, "\n", fixed=TRUE)
      link <- substr(redirects[[1]][1], 7, nchar(redirects[[1]][1]))
      
      redirect <- strsplit(link, "://", fixed=TRUE)
      protocol <- redirect[[1]][1]
      if (protocol == "merovingian") {
        # retry auth on same connection, we will get a new challenge
        .mapiAuthenticate(con, dbname, user, password, endhashfunc)
      }
      if (protocol == "monetdb") {
        stop("Forwarding to another server (", link, ") not supported.")
      }
    }
    if (respKey == MSG_MESSAGE) {
      stop(paste("Authentication error:", authResponse))
    }
  } else {
    if (getOption("monetdb.debug.mapi", F)) message("II: Authentication successful.")
    # setting some server parameters...not sure if this should happen here
    .mapiWrite(con, paste0("Xreply_size ", REPLY_SIZE)); .mapiRead(con)
    .mapiWrite(con, "Xauto_commit 1"); .mapiRead(con)
  }
}

.monetdbd.command <- function(passphrase, host="localhost", port=50000L, timeout=86400L) {
  socket <- .mapiConnect(host, port, timeout)
  .mapiAuthenticate(socket, "merovingian", "monetdb", passphrase, language="control")
  .mapiWrite(socket, "#all status\n")
  ret <- .mapiRead(socket)
  .mapiDisconnect(socket)
  return (ret)
}

