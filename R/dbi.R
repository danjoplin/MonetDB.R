C_LIBRARY <- "MonetDB.R"

.onLoad <- function(lib, pkg) {
  if (getOption("monetdb.clib", FALSE)) {
    library.dynam( C_LIBRARY, pkg, lib )
    .Call("mapiInit", PACKAGE=C_LIBRARY)
  }
}

# Make S4 aware of S3 classes
setOldClass(c("sockconn", "connection", "monetdb_mapi_conn"))

### MonetDBDriver
setClass("MonetDBDriver", representation("DBIDriver"))

# allow instantiation of this driver with MonetDB to allow existing programs to work
MonetR <- MonetDB <- MonetDBR <- MonetDB.R <- function() {
  new("MonetDBDriver")
}

setMethod("dbIsValid", "MonetDBDriver", def=function(dbObj, ...) {
  return(invisible(TRUE)) # driver object cannot be invalid
})

setMethod("dbUnloadDriver", "MonetDBDriver", def=function(drv, ...) {
  return(invisible(TRUE)) # there is nothing to really unload here...
})

setMethod("dbGetInfo", "MonetDBDriver", def=function(dbObj, ...)
  list(name="MonetDBDriver", 
       driver.version=packageVersion("MonetDB.R"), 
       DBI.version=packageVersion("DBI"), 
       client.version="NA", 
       max.connections=125) # R can only handle 128 connections, three of which are pre-allocated
)

# shorthand for connecting to the DB, very handy, e.g. dbListTables(mc("acs"))
mc <- function(dbname="demo", user="monetdb", password="monetdb", host="localhost", port=50000L, 
               timeout=86400L, wait=FALSE, language="sql", ...) {
  
  dbConnect(MonetDB.R(), dbname, user, password, host, port, timeout, wait, language, ...)
}

mq <- function(dbname, query, ...) {
  conn <- mc(dbname, ...)
  res <- dbGetQuery(conn, query)
  dbDisconnect(conn)
  return(res)
}

setMethod("dbConnect", "MonetDBDriver", def=function(drv, dbname="demo", user="monetdb", 
                                                     password="monetdb", host="localhost", port=50000L, timeout=86400L, wait=FALSE, language="sql", 
                                                     ..., url="") {
  
  if (substring(url, 1, 10) == "monetdb://") {
    dbname <- url
  }
  timeout <- as.integer(timeout)
  
  if (substring(dbname, 1, 10) == "monetdb://") {
    rest <- substring(dbname, 11, nchar(dbname))
    # split at /, so we get the dbname
    slashsplit <- strsplit(rest, "/", fixed=TRUE)
    hostport <- slashsplit[[1]][1]
    dbname <- slashsplit[[1]][2]
    
    # count the number of : in the string
    ndc <- nchar(hostport) - nchar(gsub(":","",hostport,fixed=T))
    if (ndc == 0) {
      host <- hostport
    }
    if (ndc == 1) { # ipv4 case, any ipv6 address has more than one :
      hostportsplit <- strsplit(hostport, ":", fixed=TRUE)
      host <- hostportsplit[[1]][1]
      port <- hostportsplit[[1]][2]
    }
    if (ndc > 1) { # ipv6 case, now we only need to check for ]:
      if (length(grep("]:", hostport, fixed=TRUE)) == 1) { # ipv6 with port number
        hostportsplit <- strsplit(hostport, "]:", fixed=TRUE)
        host <- substring(hostportsplit[[1]][1],2)
        port <- hostportsplit[[1]][2]
      }
      else {
        host <- hostport
      }
    }
  }
  # this is important, otherwise we'll trip an assertion
  port <- as.integer(port)
  
  # validate port number
  if (length(port) != 1 || port < 1 || port > 65535) {
    stop("Illegal port number ",port)
  }
  
  if (getOption("monetdb.debug.mapi", F)) message("II: Connecting to MonetDB on host ", host, " at "
                                                  ,"port ", port, " to DB ", dbname, " with user ", user, " and a non-printed password, timeout is "
                                                  , timeout, " seconds.")
  socket <- FALSE
  if (wait) {
    repeat {
      continue <- FALSE
      tryCatch ({
        # open socket with 5-sec timeout so we can check whether everything works
        suppressWarnings(socket <- socket <<- .mapiConnect(host, port, 5))
        # authenticate
        .mapiAuthenticate(socket, dbname, user, password, language=language)
        .mapiDisconnect(socket)
        break
      }, error = function(e) {
        if ("connection" %in% class(socket)) {
          close(socket)
        }
        message("Server not ready(", e$message, "), retrying (ESC or CTRL+C to abort)")
        Sys.sleep(1)
        continue <<- TRUE
      })
    }
  }
  
  # make new socket with user-specified timeout
  socket <- .mapiConnect(host, port, timeout) 
  .mapiAuthenticate(socket, dbname, user, password, language=language)
  connenv <- new.env(parent=emptyenv())
  connenv$lock <- 0
  connenv$deferred <- list()
  connenv$exception <- list()
  
  conn <- new("MonetDBConnection", socket=socket, connenv=connenv, Id=-1L)
  if (getOption("monetdb.sequential", F)) {
    message("MonetDB: Switching to single-threaded query execution.")
    dbSendQuery(conn, "set optimizer='sequential_pipe'")
  }
  
  return(conn)
  
}, 
valueClass="MonetDBConnection")


### MonetDBConnection
setClass("MonetDBConnection", representation("DBIConnection", socket="ANY", 
                                             connenv="environment", fetchSize="integer", Id="integer"))

setMethod("dbGetInfo", "MonetDBConnection", def=function(dbObj, ...) {
  envdata <- dbGetQuery(dbObj, "SELECT name, value from sys.env()")
  ll <- as.list(envdata$value)
  names(ll) <- envdata$name
  ll$name <- "MonetDBConnection"
  return(ll)
})

setMethod("dbIsValid", "MonetDBConnection", def=function(dbObj, ...) {
  return(invisible(!is.na(tryCatch({dbGetInfo(dbObj);TRUE}, error=function(e){NA}))))
})

setMethod("dbDisconnect", "MonetDBConnection", def=function(conn, ...) {
  .mapiDisconnect(conn@socket)
  return(invisible(TRUE))
})

setMethod("dbListTables", "MonetDBConnection", def=function(conn, ..., sys_tables=F, schema_names=F, quote=F) {
  q <- "select schemas.name as sn, tables.name as tn from sys.tables join sys.schemas on tables.schema_id=schemas.id"
  if (!sys_tables) q <- paste0(q, " where tables.system=false")
  df <- dbGetQuery(conn, q)
  if (quote) {
    df$tn <- paste0("\"", df$tn, "\"")
  }
  res <- df$tn
  if (schema_names) {
    if (quote) {
      df$sn <- paste0("\"", df$sn, "\"")
    }
    res <- paste0(df$sn, ".", df$tn)
  }
  return(as.character(res))
})

if (is.null(getGeneric("dbTransaction"))) setGeneric("dbTransaction", function(conn, ...) 
  standardGeneric("dbTransaction"))

setMethod("dbTransaction", signature(conn="MonetDBConnection"),  def=function(conn, ...) {
  dbBegin(conn)
  warning("dbTransaction() is deprecated, use dbBegin() from now.")
  invisible(TRUE)
})

setMethod("dbBegin", "MonetDBConnection", def=function(conn, ...) {
  dbSendQuery(conn, "START TRANSACTION")
  invisible(TRUE)
})

setMethod("dbCommit", "MonetDBConnection", def=function(conn, ...) {
  dbSendQuery(conn, "COMMIT")
  invisible(TRUE)
})

setMethod("dbRollback", "MonetDBConnection", def=function(conn, ...) {
  dbSendQuery(conn, "ROLLBACK")
  invisible(TRUE)
})

setMethod("dbListFields", "MonetDBConnection", def=function(conn, name, ...) {
  if (!dbExistsTable(conn, name))
    stop(paste0("Unknown table: ", name));
  df <- dbGetQuery(conn, paste0("select columns.name as name from sys.columns join sys.tables on \
                                columns.table_id=tables.id where tables.name='", name, "';"))  
  df$name
})

setMethod("dbExistsTable", "MonetDBConnection", def=function(conn, name, ...) {
  # TODO: this is evil... 
  return(tolower(gsub("(^\"|\"$)","",as.character(name))) %in% 
           tolower(dbListTables(conn,sys_tables=T)))
})

setMethod("dbGetException", "MonetDBConnection", def=function(conn, ...) {
  conn@connenv$exception
})

setMethod("dbReadTable", "MonetDBConnection", def=function(conn, name, ...) {
  if (!dbExistsTable(conn, name))
    stop(paste0("Unknown table: ", name));
  dbGetQuery(conn,paste0("SELECT * FROM ", name))
})

# This one does all the work in this class
setMethod("dbSendQuery", signature(conn="MonetDBConnection", statement="character"),  
          def=function(conn, statement, ..., list=NULL, async=FALSE) {
            
            if(!is.null(list) || length(list(...))){
              if (length(list(...))) statement <- .bindParameters(statement, list(...))
              if (!is.null(list)) statement <- .bindParameters(statement, list)
            }	
            conn@connenv$exception <- list()
            env <- NULL
            if (getOption("monetdb.debug.query", F))  message("QQ: '", statement, "'")
            resp <- .mapiParseResponse(.mapiRequest(conn, paste0("s", statement, ";"), async=async))
            
            env <- new.env(parent=emptyenv())
            
            if (resp$type == Q_TABLE) {
              # we have to pass this as an environment to make conn object available to result for fetching
              env$success = TRUE
              env$conn <- conn
              env$data <- resp$tuples
              resp$tuples <- NULL # clean up
              env$info <- resp
              env$delivered <- 0
              env$query <- statement
              env$open <- TRUE
            }
            if (resp$type == Q_UPDATE || resp$type == Q_CREATE || resp$type == MSG_ASYNC_REPLY) {
              env$success = TRUE
              env$conn <- conn
              env$query <- statement
              env$info <- resp
              
            }
            if (resp$type == MSG_MESSAGE) {
              env$success = FALSE
              env$conn <- conn
              env$query <- statement
              env$info <- resp
              env$message <- resp$message
            }
            
            if (!env$success) {
              sp <- strsplit(env$message, "!", fixed=T)[[1]]
              # truncate statement to not hide actual error message
              if (nchar(statement) > 100) { statement <- paste0(substring(statement, 1, 100), "...") }
              if (length(sp) == 3) {
                errno <- sp[[2]]
                errmsg <- sp[[3]]
                conn@connenv$exception <- list(errNum=errno, errMsg=errmsg)
                stop("Unable to execute statement '", statement, "'.\nServer says '", errmsg, "' [#", 
                     errno, "].")
              }
              else {
                conn@connenv$exception <- list(errNum=NA, errMsg=env$message)
                stop("Unable to execute statement '", statement, "'.\nServer says '", env$message, "'.")
              }
            }
            
            return(new("MonetDBResult", env=env))
          })



# quoting
setMethod("dbQuoteIdentifier", c("MonetDBConnection", "character"), function(conn, x, ...) {
  qts <- !grepl("^[a-z][a-z0-9_]+$",x,perl=T)
  x[qts] <- paste('"', gsub('"', '""', x[qts], fixed = TRUE), '"', sep = "")
  SQL(x)
})

# overload as per DBI documentation
setMethod("dbQuoteIdentifier", c("MonetDBConnection", "SQL"), function(conn, x, ...) {x})

# adapted from RMonetDB, very useful...
setMethod("dbWriteTable", "MonetDBConnection", def=function(conn, name, value, overwrite=FALSE, 
                                                            append=FALSE, csvdump=FALSE, transaction=TRUE,...) {
  if (is.vector(value) && !is.list(value)) value <- data.frame(x=value)
  if (length(value)<1) stop("value must have at least one column")
  if (is.null(names(value))) names(value) <- paste("V", 1:length(value), sep='')
  if (length(value[[1]])>0) {
    if (!is.data.frame(value)) value <- as.data.frame(value, row.names=1:length(value[[1]]))
  } else {
    if (!is.data.frame(value)) value <- as.data.frame(value)
  }
  if (overwrite && append) {
    stop("Setting both overwrite and append to true makes no sense.")
  }
  qname <- make.db.names(conn, name)
  if (dbExistsTable(conn, qname)) {
    if (overwrite) dbRemoveTable(conn, qname)
    if (!overwrite && !append) stop("Table ", qname, " already exists. Set overwrite=TRUE if you want 
                                    to remove the existing table. Set append=TRUE if you would like to add the new data to the 
                                    existing table.")
  }
  if (!dbExistsTable(conn, qname)) {
    fts <- sapply(value, dbDataType, dbObj=conn)
    fdef <- paste(make.db.names(conn, names(value)), fts, collapse=', ')
    ct <- paste("CREATE TABLE ", qname, " (", fdef, ")", sep= '')
    dbSendUpdate(conn, ct)
  }
  if (length(value[[1]])) {
    if (csvdump) {
      tmp <- tempfile(fileext = ".csv")
      write.table(value, tmp, sep = ",", quote = TRUE,row.names = FALSE, col.names = FALSE,na="")
      dbSendQuery(conn, paste0("COPY ",format(nrow(value), scientific=FALSE)," RECORDS INTO ", qname,
                               " FROM '", tmp, "' USING DELIMITERS ',','\\n','\"' NULL AS ''"))
      file.remove(tmp) 
    } else {
      vins <- paste("(", paste(rep("?", length(value)), collapse=', '), ")", sep='')
      if (transaction) dbBegin(conn)
      # chunk some inserts together so we do not need to do a round trip for every one
      splitlen <- 0:(nrow(value)-1) %/% getOption("monetdb.insert.splitsize", 1000)
      lapply(split(value, splitlen), 
             function(valueck) {
               bvins <- c()
               for (j in 1:length(valueck[[1]])) bvins <- c(bvins,.bindParameters(vins, as.list(valueck[j, ])))
               dbSendUpdate(conn, paste0("INSERT INTO ", qname, " VALUES ",paste0(bvins, collapse=", ")))
             })
      if (transaction) dbCommit(conn)
    }
  }
  return(invisible(TRUE))
  })

setMethod("dbDataType", signature(dbObj="MonetDBConnection", obj = "ANY"), def = function(dbObj, 
                                                                                          obj, ...) {
  if (is.logical(obj)) "BOOLEAN"
  else if (is.integer(obj)) "INTEGER"
  else if (is.numeric(obj)) "DOUBLE PRECISION"
  else if (is.raw(obj)) "BLOB"
  else "STRING"
}, valueClass = "character")


setMethod("dbRemoveTable", "MonetDBConnection", def=function(conn, name, ...) {
  if (dbExistsTable(conn, name)) {
    dbSendUpdate(conn, paste("DROP TABLE", tolower(name)))
    return(invisible(TRUE))
  }
  return(invisible(FALSE))
})

# for compatibility with RMonetDB (and dbWriteTable support), we will allow parameters to this 
# method, but will not use prepared statements internally
if (is.null(getGeneric("dbSendUpdate"))) setGeneric("dbSendUpdate", function(conn, statement, ..., 
                                                                             async=FALSE) standardGeneric("dbSendUpdate"))
setMethod("dbSendUpdate", signature(conn="MonetDBConnection", statement="character"),  
          def=function(conn, statement, ..., list=NULL, async=FALSE) {
            
            if(!is.null(list) || length(list(...))){
              if (length(list(...))) statement <- .bindParameters(statement, list(...))
              if (!is.null(list)) statement <- .bindParameters(statement, list)
            }
            res <- dbSendQuery(conn, statement, async=async)
            if (!res@env$success) {
              stop(paste(statement, "failed!\nServer says:", res@env$message))
            }
            return(invisible(TRUE))
          })

# this can be used in finalizers to not mess up the socket
if (is.null(getGeneric("dbSendUpdateAsync"))) setGeneric("dbSendUpdateAsync", function(conn, 
                                                                                       statement, ...) standardGeneric("dbSendUpdateAsync"))
setMethod("dbSendUpdateAsync", signature(conn="MonetDBConnection", statement="character"),  
          def=function(conn, statement, ..., list=NULL) {
            
            dbSendUpdate(conn, statement, async=TRUE)
          })


.bindParameters <- function(statement, param) {
  for (i in 1:length(param)) {
    value <- param[[i]]
    valueClass <- class(value)
    if (is.na(value)) 
      statement <- sub("?", "NULL", statement, fixed=TRUE)
    else if (valueClass %in% c("numeric", "logical", "integer"))
      statement <- sub("?", value, statement, fixed=TRUE)
    else if (valueClass == c("raw"))
      stop("raw() data is so far only supported when reading from BLOBs")
    else
      statement <- sub("?", paste("'", .mapiQuote(toString(value)), "'", sep=""), statement, 
                       fixed=TRUE)
  }
  return(statement)
}

# quote strings when sending them to the db. single quotes are most critical.
# null bytes are not supported
.mapiQuote <- function(str) {
  qs <- ""
  chrs <- unlist(strsplit(str, "", fixed=TRUE))
  for (chr in chrs) {
    f <- ""
    if (chr == "\n") f <- qs <- paste0(qs, "\\", "n")
    if (chr == "\t") f <- qs <- paste0(qs, "\\", "t")
    if (chr == "'" ) f <- qs <- paste0(qs, "\\'")
    if (nchar(f) == 0) qs <- paste0(qs, chr)
  }
  qs
}


### MonetDBResult
setClass("MonetDBResult", representation("DBIResult", env="environment"))
# 
# .CT_NUM <- 1L
# .CT_CHR <- 2L
# .CT_CHRR <- 3L
# .CT_BOOL <- 4L
# .CT_RAW <- 5L
# .CT_INT <- 6L
# .CT_LONG <- 7L
# .CT_DATE <- 8L

r.types <- r.type.defaults <- c("TINYINT"="integer", "SMALLINT"="integer", "INT"="integer", 
                  "BIGINT"="numeric", "REAL"="numeric", "DOUBLE"="numeric", "DECIMAL"="numeric", "WRD"="numeric", 
                  "CHAR"="character", "VARCHAR"="character", "CLOB"="character", "STR"="character", 
                  "INTERVAL"="character", "DATE"="character", "TIME"="character", "TIMESTAMP"="character", 
                  "BOOLEAN"="logical", "BLOB"="raw")

setCustomRTypes <- function(custom.types) {
  stopifnot(all(names(custom.types) %in% names(r.types)), all(sapply(custom.types, is.function)))
  r.types[custom.types] <- custom.types
}

resetRTypes <- function() {
  r.types <- r.type.defaults
}

monetdbRtype <- function(dbType) {
  out <- r.type.defaults[toupper(dbType)]
  if (is.na(out)) stop("Unknown DB type ", dbType)
  return(out)
}

setMethod("fetch", signature(res="MonetDBResult", n="numeric"), def=function(res, n, ...) {
  # dbGetQuery() still calls fetch(), thus no error message yet 
  # warning("fetch() is deprecated, use dbFetch()")
  dbFetch(res, n, ...)
})

# most of the heavy lifting here
setMethod("dbFetch", signature(res="MonetDBResult", n="numeric"), def=function(res, n, ...) {
  if (!res@env$success) {
    stop("Cannot fetch results from error response, error was ", res@env$info$message)
  }
  if (!dbIsValid(res)) {
    stop("Cannot fetch results from closed response.")
  }
  
  # okay, so we arrive here with the tuples from the first result in res@env$data as a list
  info <- res@env$info
  stopifnot(res@env$delivered <= info$rows, info$index <= info$rows)
  remaining <- info$rows - res@env$delivered
  
  if (n < 0) {
    n <- remaining
  } else {
    n <- min(n, remaining)
  }
  
  # prepare the result holder df with columns of the appropriate type
  ct <- sapply(info$types, monetdbRtype)
  df <- sapply(ct, function(k) as(NULL, k))
  names(df) <- info$names

  # we have delivered everything, return empty df (spec is not clear on this one...)
  if (n < 1) {
    return(data.frame(df))
  }
  
  # if our tuple cache in res@env$data does not contain n rows, we fetch from server until it does
  if (length(res@env$data) < n) {
    cresp <- .mapiParseResponse(.mapiRequest(res@env$conn, paste0("Xexport ", .mapiLongInt(info$id), 
                                                                  " ", .mapiLongInt(info$index), " ", .mapiLongInt(n-length(res@env$data)))))
    stopifnot(cresp$type == Q_BLOCK && cresp$rows > 0)
    
    res@env$data <- c(res@env$data, cresp$tuples)
    info$index <- info$index + cresp$rows
  }
  
  # convert tuple string vector into matrix so we can access a single column efficiently
  # call to a faster C implementation for the annoying task of splitting everyting into fields
  parts <- .Call("mapiSplit", res@env$data[1:n], as.integer(info$cols), PACKAGE=C_LIBRARY)
  
  # convert values column by column
  for (j in seq.int(info$cols)) {	
    df[[j]] <- as(parts[[j]], ct[[j]])
  }
  
  # remove the already delivered tuples from the background holder or clear it altogether
  if (n+1 >= length(res@env$data)) {
    res@env$data <- character()
  } else {
    res@env$data <- res@env$data[seq(n+1, length(res@env$data))]
  }
  res@env$delivered <- res@env$delivered + n
  
  # this is a trick so we do not have to call data.frame(), which is expensive
#   attr(df, "row.names") <- c(NA_integer_, length(df[[1]]))
  class(df) <- "data.frame"
  
  return(df)
})

setMethod("dbClearResult", "MonetDBResult", def = function(res, ...) {
  if (res@env$info$type == Q_TABLE) {
    resid <- res@env$info$id
    if (!is.null(resid) && !is.na(resid) && is.numeric(resid)) {
      .mapiRequest(res@env$conn, paste0("Xclose ", resid), async=TRUE)
      res@env$open <- FALSE
    }
  }
  return(invisible(TRUE))
}, valueClass = "logical")

setMethod("dbHasCompleted", "MonetDBResult", def = function(res, ...) {
  if (res@env$info$type == Q_TABLE) {
    return(res@env$delivered == res@env$info$rows)
  }
  return(invisible(TRUE))
}, valueClass = "logical")

setMethod("dbIsValid", signature(dbObj="MonetDBResult"), def=function(dbObj, ...) {
  if (dbObj@env$info$type == Q_TABLE) {
    return(dbObj@env$open)
  }
  return(invisible(TRUE))
})

monetTypes <- rep(c("integer", "integer64", "numeric", "character", "character", "POSIXct", "logical", "raw"), c(3, 1, 6, 3, 3, 1,1, 1))
names(monetTypes) <- c(c("TINYINT", "SMALLINT", "INT"),
                       c("BIGINT"),
                       c("HUGEINT", "REAL", "DOUBLE", "DECIMAL", "WRD"), 
                       c("CHAR", "VARCHAR", "CLOB"), 
                       c("INTERVAL", "DATE", "TIME"), 
                       "TIMESTAMP",
                       "BOOLEAN", 
                       "BLOB")


setMethod("dbColumnInfo", "MonetDBResult", def = function(res, ...) {
  return(data.frame(field.name=res@env$info$names, field.type=res@env$info$types, 
                    data.type=monetTypes[res@env$info$types]))	
}, 
valueClass = "data.frame")

setMethod("dbGetInfo", "MonetDBResult", def=function(dbObj, ...) {
  return(list(statement=dbObj@env$query, rows.affected=0, row.count=dbObj@env$info$rows, 
              has.completed=dbHasCompleted(dbObj), is.select=TRUE))	
}, valueClass="list")

# copied from RMonetDB, no java-specific things in here...
monet.read.csv <- monetdb.read.csv <- function(conn, files, tablename, nrows, header=TRUE, 
                                               locked=FALSE, na.strings="", nrow.check=500, delim=",", newline="\\n", quote="\"", ...){
  
  if (length(na.strings)>1) stop("na.strings must be of length 1")
  headers <- lapply(files, read.csv, sep=delim, na.strings=na.strings, quote=quote, nrows=nrow.check, 
                    ...)
  
  if (length(files)>1){
    nn <- sapply(headers, ncol)
    if (!all(nn==nn[1])) stop("Files have different numbers of columns")
    nms <- sapply(headers, names)
    if(!all(nms==nms[, 1])) stop("Files have different variable names")
    types <- sapply(headers, function(df) sapply(df, dbDataType, dbObj=conn))
    if(!all(types==types[, 1])) stop("Files have different variable types")
  } 
  
  dbWriteTable(conn, tablename, headers[[1]][FALSE, ])
  
  delimspec <- paste0("USING DELIMITERS '", delim, "','", newline, "','", quote, "'")
  
  if(header || !missing(nrows)){
    if (length(nrows)==1) nrows <- rep(nrows, length(files))
    for(i in seq_along(files)) {
      thefile <- normalizePath(files[i])
      dbSendUpdate(conn, paste("COPY", format(nrows[i], scientific=FALSE), "OFFSET 2 RECORDS INTO", 
                               tablename, "FROM", paste("'", thefile, "'", sep=""), delimspec, "NULL as", paste("'", 
                                                                                                                na.strings[1], "'", sep=""), if(locked) "LOCKED"))
    }
  } else {
    for(i in seq_along(files)) {
      thefile <- normalizePath(files[i])
      dbSendUpdate(conn, paste0("COPY INTO ", tablename, " FROM ", paste("'", thefile, "'", sep=""), 
                                delimspec, "NULL as ", paste("'", na.strings[1], "'", sep=""), if(locked) " LOCKED "))
    }
  }
  dbGetQuery(conn, paste("select count(*) from", tablename))
}
