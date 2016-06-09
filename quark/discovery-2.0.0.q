quark 0.7;

package datawire_discovery 2.0.0;

use ./util.q;
use ./discovery_protocol.q;

import quark.concurrent;
import quark.reflect;

import discovery.protocol;
import util.internal;

/*
  Context:

    For phase one, all our user wants to do is have a convenient
    library to get an address to connect to that is backed by a
    realtime discovery service rather than DNS. The mechanism for
    connecting is entirely in the user's code, all we do is provide
    an address (likely in the form of a url, but really it's just an
    opaque string that was advertised by a service instance).

    Behind the scenes we will do client side load balancing and
    possibly fancier routing in the future, but the user doesn't
    observe this directly through the API. The user *does* observe
    this indirectly because they don't need to deploy a central load
    balancer.

    Conceptually, we should strive to be a drop-in replacement for
    dns, with the one difference being that the server process is
    creating the dns record directly rather than a system
    administrator.

  API usage sketch:

    Server:

      from discovery import Discovery, Node
      disco = Discovery.get("https://disco.datawire.io")
      ... bind to port
      disco.register(Node("service", "address", "version"))
      ... serve stuff

    Client:

      from discovery import Discovery, Node
      disco = Discovery.get("https://disco.datawire.io")
      node = disco.resolve("servicefoo")

      ... create a connection to node.address
      ... use connection
 */

/*
  TODO:
    - rename Cluster to something reasonable, e.g. ServiceInfo
    - disco.lookup -> Cluster (renamed)
    - disco.resolve -> is convenience for disco.lookup("<service>").choose()
    - disco.register -> Cluster (renamed), use to communicate error info on registry.
    - make Cluster (renamed) be the mutable, asynchronously updated thing
    - maybe make Node immutable?
*/

namespace discovery {

  @doc("The Cluster class holds a set of nodes associated with the same service.")
  class Cluster {
    List<Node> nodes = [];
    int idx = 0;

    Node choose() {
      if (nodes.size() > 0) {
        int choice = idx % nodes.size();
        idx = idx + 1;
        return nodes[choice];
      }
      else {
        return null;
      }
    }

    void add(Node node) {
      int idx = 0;

      while (idx < nodes.size()) {
        Node ep = nodes[idx];
      
        if (ep.address == null || ep.address == node.address) {
          ep.update(node);
          return;
        }

        idx = idx + 1;
      }

      nodes.add(node);
    }

    String toString() {
      String result = "Cluster(";

      int idx = 0;

      while (idx < nodes.size()) {
        if (idx > 0) {
          result = result + ", ";
        }

        result = result + nodes[idx].toString();
        idx = idx + 1;
      }

      result = result + ")";
      return result;
    }
  }

  @doc("The Node class captures address and metadata information about a")
  @doc("server functioning as a service instance.")
  class Node extends Future {
    @doc("The service name.")
    String service;
    @doc("The service version.")
    String version;
    @doc("The address from which clients can reach the server.")
    String address;
    @doc("Additional metadata associated with this service instance.")
    Map<String,Object> properties;

    void update(Node node) {
      service = node.service;
      version = node.version;
      address = node.address;
      properties = node.properties;
      self.finish(null);
    }

    String toString() {
      // XXX: this doesn't get mapped into __str__, etc in targets
      String result = "Node(";

      if (service == null) {
        result = result + "<unnamed>";
      }
      else {
        result = result + service;
      }

      result = result + ": ";

      if (address == null) {
        result = result + "<unlocated>";
      }
      else {
        result = result + address;
      }

      if (version != null) {
        result = result + ", " + version;
      }

      result = result + ")";

      if (properties != null) {
        result = result + " " + properties.toString();
      }

      return result;
    }
  }

  @doc("The Discovery class functions as a conduit to the discovery service.")
  @doc("Using it, an application can register and/or lookup service instances.")
  class Discovery {
    String url;
    String token;
    bool gateway = false;

    static Logger logger = new Logger("discovery");

    // Nodes we advertise to the disco service.
    Map<String,Cluster> registered = new Map<String,Cluster>();

    // Nodes the disco says are available, as well as nodes for
    // which we are awaiting resolution.
    Map<String,Cluster> services = new Map<String,Cluster>();

    bool started = false;
    Lock mutex = new Lock();
    DiscoClient client;

    @doc("Construct a Discovery object. You must connect the object to a")
    @doc("discovery server before you can do anything; see connect() and")
    @doc("connectTo()")
    Discovery() {
      logger.info("hello");
    }

    @doc("Lock and make sure we have a client established.")
    void _lock() {
      mutex.acquire();

      logger.info("locked");

      if (client == null) {
        client = new DiscoClient(self);
        logger.info("client ho!");
      }
    }

    @doc("Release the lock")
    void _release() {
      mutex.release();
      logger.info("released");
    }

    @doc("Connect to a specific discovery server. Most callers will just want")
    @doc("connect().")
    Discovery connectTo(String url) {
      // Don't use self._lock() here -- manage the lock by hand since we're
      // messing with the client by hand.
      mutex.acquire();

      logger.info("will connect to " + url);

      self.url = url;
      self.client = null;

      mutex.release();

      return self;
    }

    @doc("Connect to the default discovery server. If DATAWIRE_DISCOVERY_URL")
    @doc("is in the environment, it specifies the default; if not, we'll talk to")
    @doc("disco.datawire.io.")
    Discovery connect() {
      EnvironmentVariable ddu = EnvironmentVariable("DATAWIRE_DISCOVERY_URL");
      String url = ddu.orElseGet("disco.datawire.io");

      return self.connectTo(url);
    }

    @doc("Set the token we'll use to talk to the server.")
    Discovery withToken(String token) {
      self._lock();
      logger.info("using token " + token);
      self.token = token;
      self._release();

      return self;
    }

    @doc("Start the uplink to the discovery service.")
    Discovery start() {
      self._lock();

      if (!started) {
        started = true;
        client.start();
      }

      self._release();
      return self;
    }

    @doc("Stop the uplink to the discovery service.")
    Discovery stop() {
      self._lock();

      if (started) {
        started = false;
        client.stop();
      }

      self._release();
      return self;
    }

    @doc("Register info about a service node with the discovery service.")
    void register(Node node) {
      self._lock();

      String service = node.service;

      if (!registered.contains(service)) {
        registered[service] = new Cluster();
      }

      registered[service].add(node);
      client.register(node);

      self._release();
    }

    @doc("Resolve a service name into an available service node.")
    Node resolve(String service) {
      Node result;
      self._lock();

      if (services.contains(service)) {
        result = services[service].choose();
      }
      else {
        result = new Node();
        result.service = service;
        services[service] = new Cluster();
        services[service].add(result);
        client.resolve(result);
      }

      self._release();
      return result;
    }
  }
}
