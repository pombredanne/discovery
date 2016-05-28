package io.datawire.discovery.v2

import com.hazelcast.core.Hazelcast
import com.hazelcast.core.HazelcastInstance
import discovery.Node
import discovery.protocol.*
import io.datawire.discovery.auth.DiscoveryAuthHandler
import io.datawire.discovery.v2.model.ServiceKey
import io.datawire.discovery.v2.model.ServiceRecord
import io.datawire.discovery.v2.model.ServiceStore
import io.datawire.discovery.v2.service.ForwardingServiceStore
import io.datawire.discovery.v2.service.ReplicatedServiceStore
import io.vertx.core.AbstractVerticle
import io.vertx.core.Handler
import io.vertx.core.json.JsonObject
import io.vertx.core.logging.LoggerFactory
import io.vertx.ext.auth.jwt.JWTAuth
import io.vertx.ext.web.Router
import io.vertx.ext.web.RoutingContext
import io.vertx.ext.web.handler.CorsHandler
import java.util.*


class Discovery : AbstractVerticle() {

  private val logger    = LoggerFactory.getLogger(Discovery::class.java)
  private val hazelcast = Hazelcast.newHazelcastInstance()

  class QuarkBugWorkaround : DiscoHandler {
    override fun onActive(active: Active?) = throw UnsupportedOperationException()
    override fun onExpire(expire: Expire?) = throw UnsupportedOperationException()
    override fun onClear(reset: Clear?)    = throw UnsupportedOperationException()
  }

  init {
    QuarkBugWorkaround()
  }

  private fun configureAuthHandler(router: Router) {
    val authConfig = config().getJsonObject("authentication") ?: throw IllegalArgumentException("Authentication config is missing!")

    when (authConfig.getString("type", "none")?.toLowerCase()) {
      "jwt" -> {
        val protectedPath  = authConfig.getString("path", "/*")
        val keystoreConfig = authConfig.getJsonObject("keyStore")

        val jwt = JWTAuth.create(vertx, keystoreConfig)
        val authHandler = DiscoveryAuthHandler(jwt, "/health")
        router.route(protectedPath).handler(authHandler)
      }
      else -> return
    }
  }

  private fun configureCorsHandler(router: Router) {
    router.route("/*").handler(CorsHandler.create("*"))
  }

  override fun start() {
    val router = Router.router(vertx)

    configureAuthHandler(router)
    configureCorsHandler(router)

    router.route("/").handler(DiscoConnection())

    val server = vertx.createHttpServer()
    server.requestHandler { router.accept(it) }.listen(52689)
  }

  inner class DiscoConnection() : Handler<RoutingContext> {

    lateinit var serviceStore: ServiceStore

    override fun handle(ctx: RoutingContext) {
      val request = ctx.request()
      val socket  = request.upgrade()

      val tenant = if (config().getJsonObject("authentication").getString("type", "none") == "none") {
        "default"
      } else {
        ctx.user().principal().getString("aud")
      }

      // TODO: Abstract this bit a bit.
      val replicatedMap = hazelcast.getReplicatedMap<String, ServiceRecord>("discovery.services.$tenant")
      serviceStore = ForwardingServiceStore(ReplicatedServiceStore(replicatedMap))

//      serviceStore.addRecord(ServiceRecord(ServiceKey("foo", "foo-host"), "1.0.0", mapOf()), 20)
//      serviceStore.addRecord(ServiceRecord(ServiceKey("bar", "bar-host"), "1.0.0", mapOf()), 40)
//      serviceStore.addRecord(ServiceRecord(ServiceKey("baz", "baz-host"), "1.0.0", mapOf()), 60)

      vertx.sharedData().getCounter("discovery[${deploymentID()}].$tenant.connections") { getCounter ->
        if (getCounter.succeeded()) {
          getCounter.result().incrementAndGet { increment ->

            if (increment.succeeded() && increment.result() == 1L) {
              logger.info(
                  "First connected client for tenant on this node. Registering services change listener (node: ${deploymentID()}, tenant: $tenant)")

              val entryListenerId = replicatedMap.addEntryListener(ServicesChangeListener(vertx.eventBus()))

              vertx
                  .sharedData()
                  .getLocalMap<String, String>("discovery.services.event-listeners")
                  .put(tenant, entryListenerId)

            } else if(increment.failed()) {
              logger.error("Could not increment tenant connection counter (tenant: $tenant)")
              socket.close()
            }

          }
        }
      }

      val notificationsAddress = "datawire.discovery.$tenant.services.notifications"
      val notificationsHandler = vertx.eventBus().localConsumer<String>(notificationsAddress)
      notificationsHandler.handler {
        socket.writeFinalTextFrame(it.body())
      }

      // A discovery.protocol.clear message is always sent upon a connection being established. The clear message is
      // sent just before the server dumps all known Active services to the client.
      socket.writeFinalTextFrame(Clear().encode())
      vertx.executeBlocking<Void>(
          {
            future -> serviceStore.getRecords().forEach { socket.writeFinalTextFrame(it.toActive().encode()) }
            future.complete()
          }, false, { })


      socket.handler { buffer ->
        val event = DiscoveryEvent.decode(buffer.toString(Charsets.UTF_8))
        handle(tenant, event)
      }

      socket.closeHandler {
        if (notificationsHandler.isRegistered) {
          logger.debug("Unregistering client service store notification handler")
          notificationsHandler.unregister()
        }
      }
    }

    fun handle(tenant: String, event: DiscoveryEvent) {
      logger.debug("Handling {} event (tenant: {})", event.javaClass.simpleName, tenant)
      when (event) {
        is Active -> onActive(tenant, event)
        is Expire -> onExpire(tenant, event)
        is Clear  -> onClear(tenant, event)
        else      -> throw UnsupportedOperationException("TODO: ERROR MESSAGE")
      }
    }

    fun onActive(tenant: String, active: Active) {
      val key = ServiceKey(active.node.service, active.node.address, tenant)
      val record = ServiceRecord(key, active.node.version, active.node.properties.mapValues { it.toString() })
      serviceStore.addRecord(record, active.ttl.toLong())
    }

    fun onExpire(tenant: String, expire: Expire) {
      val key = ServiceKey(expire.node.service, expire.node.address, tenant)
      serviceStore.removeRecord(key)
    }

    fun onClear(tenant: String, clear: Clear) {
      throw UnsupportedOperationException("TODO: Check if this needs to be handled.")
    }
  }
}