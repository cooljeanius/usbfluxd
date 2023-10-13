/*
 * client.c
 *
 * Copyright (C) 2009 Hector Martin <hector@marcansoft.com>
 * Copyright (C) 2009 Nikias Bassen <nikias@gmx.li>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 2 or version 3.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA
 */

#ifdef HAVE_CONFIG_H
#include <config.h>
#endif

#define _GNU_SOURCE 1

#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <netdb.h>
#include <sys/stat.h>
#include <arpa/inet.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <fcntl.h>

#include <stdio.h>

#include <plist/plist.h>

#include "log.h"
#include "client.h"

#include "usbmux_remote.h"

#define CMD_BUF_SIZE	0x10000
#define REPLY_BUF_SIZE	0x10000

enum client_state {
	CLIENT_COMMAND,		// waiting for command
	CLIENT_LISTEN,		// listening for devices
	CLIENT_CONNECTING1,	// issued connection request
	CLIENT_CONNECTING2,	// connection established, but waiting for response message to get sent
	CLIENT_CONNECTED,	// connected
	CLIENT_DEAD
};

struct mux_client {
	int fd;
	unsigned char *ob_buf;
	uint32_t ob_size;
	uint32_t ob_capacity;
	unsigned char *ib_buf;
	uint32_t ib_size;
	uint32_t ib_capacity;
	short events, devents;
	uint32_t connect_tag;
	int connect_device;
	enum client_state state;
	uint32_t proto_version;
	struct remote_mux *remote;
	uint32_t last_tag;
	uint32_t last_command;
	uint32_t number;
	plist_t info;
};

enum {
	CMD_LISTEN = 1,
	CMD_CONNECT,
	CMD_LIST_DEVICES,
	CMD_READ_PAIR_RECORD,
	CMD_SAVE_PAIR_RECORD,
	CMD_DELETE_PAIR_RECORD,
	CMD_READ_BUID
};

static struct collection client_list;
pthread_mutex_t client_list_mutex;
static uint32_t client_number = 0;

/**
 * Receive raw data from the client socket.
 *
 * @param client Client to read from.
 * @param buffer Buffer to store incoming data.
 * @param len Max number of bytes to read.
 * @return Same as recv() system call. Number of bytes read; when < 0 errno will be set.
 */
int client_read(struct mux_client *client, void *buffer, uint32_t len)
{
	usbfluxd_log(LL_SPEW, "client_read fd %d buf %p len %d", client->fd, buffer, len);
	if(client->state != CLIENT_CONNECTED) {
		usbfluxd_log(LL_ERROR, "Attempted to read from client %d not in CONNECTED state", client->fd);
		return -1;
	}
	return recv(client->fd, buffer, len, 0);
}

/**
 * Send raw data to the client socket.
 *
 * @param client Client to send to.
 * @param buffer The data to send.
 * @param len Number of bytes to write.
 * @return Same as system call send(). Number of bytes written; when < 0 errno will be set.
 */
int client_write(struct mux_client *client, void *buffer, uint32_t len)
{
	int sret = -1;

	usbfluxd_log(LL_SPEW, "client_write fd %d buf %p len %d", client->fd, buffer, len);
	if(client->state != CLIENT_CONNECTED) {
		usbfluxd_log(LL_ERROR, "Attempted to write to client %d not in CONNECTED state", client->fd);
		return -1;
	}

	sret = send(client->fd, buffer, len, 0);
	if (sret < 0) {
		if ((errno == EAGAIN) || (errno == EWOULDBLOCK)) {
			usbfluxd_log(LL_ERROR, "ERROR: client_write: fd %d not ready for writing", client->fd);
		} else {
			usbfluxd_log(LL_ERROR, "ERROR: client_write: sending to fd %d failed: %s", client->fd, strerror(errno));
		}
	}
	return sret;
}

/**
 * Set event mask to use for ppoll()ing the client socket.
 * Typically POLLOUT and/or POLLIN. Note that this overrides
 * the current mask, that is, it is not ORing the argument
 * into the current mask.
 *
 * @param client The client to set the event mask on.
 * @param events The event mask to sert.
 * @return 0 on success, -1 on error.
 */
int client_set_events(struct mux_client *client, short events)
{
	if((client->state != CLIENT_CONNECTED) && (client->state != CLIENT_CONNECTING2)) {
		usbfluxd_log(LL_ERROR, "client_set_events to client %d not in CONNECTED state", client->fd);
		return -1;
	}
	client->devents = events;
	if(client->state == CLIENT_CONNECTED)
		client->events = events;
	return 0;
}

int client_or_events(struct mux_client *client, short events)
{
	if((client->state != CLIENT_CONNECTED) && (client->state != CLIENT_CONNECTING2)) {
		usbfluxd_log(LL_ERROR, "client_or_events to client %d not in CONNECTED state", client->fd);
		return -1;
	}
	client->devents |= events;
	if(client->state == CLIENT_CONNECTED)
		client->events |= events;
	return 0;
}


/**
 * Wait for an inbound connection on the usbmuxd socket
 * and create a new mux_client instance for it, and store
 * the client in the client list.
 *
 * @param listenfd the socket fd to accept() on.
 * @return The connection fd for the client, or < 0 for error
 *   in which case errno will be set.
 */
int client_accept(int listenfd)
{
	struct sockaddr_un addr;
	int cfd;
	socklen_t len = sizeof(struct sockaddr_un);
	cfd = accept(listenfd, (struct sockaddr *)&addr, &len);
	if (cfd < 0) {
		usbfluxd_log(LL_ERROR, "accept() failed (%s)", strerror(errno));
		return cfd;
	}

	struct mux_client *client;
	client = malloc(sizeof(struct mux_client));
	memset(client, 0, sizeof(struct mux_client));

	client->fd = cfd;
	client->ob_buf = malloc(REPLY_BUF_SIZE);
	client->ob_size = 0;
	client->ob_capacity = REPLY_BUF_SIZE;
	client->ib_buf = malloc(CMD_BUF_SIZE);
	client->ib_size = 0;
	client->ib_capacity = CMD_BUF_SIZE;
	client->state = CLIENT_COMMAND;
	client->events = POLLIN;
	client->info = NULL;

	pthread_mutex_lock(&client_list_mutex);
	client->number = client_number++;
	collection_add(&client_list, client);
	pthread_mutex_unlock(&client_list_mutex);

#ifdef SO_PEERCRED
	if (log_level >= LL_INFO) {
		struct ucred cr;
		len = sizeof(struct ucred);
		getsockopt(cfd, SOL_SOCKET, SO_PEERCRED, &cr, &len);

		if (getpid() == cr.pid) {
			usbfluxd_log(LL_INFO, "New client on fd %d (self)", client->fd);
		} else {
			usbfluxd_log(LL_INFO, "New client on fd %d (pid %d)", client->fd, cr.pid);
		}
	}
#else
	usbfluxd_log(LL_INFO, "New client on fd %d", client->fd);
#endif
	return client->fd;
}

void client_close(struct mux_client *client)
{
	usbfluxd_log(LL_INFO, "Disconnecting client %p fd %d", client, client->fd);
	if(client->state == CLIENT_CONNECTING1 || client->state == CLIENT_CONNECTING2) {
		usbfluxd_log(LL_INFO, "Client died mid-connect, aborting device %d connection", client->connect_device);
		client->state = CLIENT_DEAD;
		//device_abort_connect(client->connect_device, client);
	}
	close(client->fd);
	if (client->remote) {
		usbmux_remote_notify_client_close(client->remote);
	}
	free(client->ob_buf);
	free(client->ib_buf);
	plist_free(client->info);
	pthread_mutex_lock(&client_list_mutex);
	collection_remove(&client_list, client);
	pthread_mutex_unlock(&client_list_mutex);
	free(client);
}

void client_get_fds(struct fdlist *list)
{
	pthread_mutex_lock(&client_list_mutex);
	FOREACH(struct mux_client *client, &client_list) {
		fdlist_add(list, FD_CLIENT, client->fd, client->events);
	} ENDFOREACH
	pthread_mutex_unlock(&client_list_mutex);
}

static int send_pkt_raw(struct mux_client *client, void *buffer, unsigned int length)
{
	usbfluxd_log(LL_DEBUG, "send_pkt_raw fd %d buffer_length %d", client->fd, length);

	uint32_t available = client->ob_capacity - client->ob_size;
	/* the output buffer _should_ be large enough, but just in case */
	if(available < length) {
		unsigned char* new_buf;
		uint32_t new_size = ((client->ob_capacity + length + 4096) / 4096) * 4096;
		usbfluxd_log(LL_DEBUG, "%s: Enlarging client %d output buffer %d -> %d", __func__, client->fd, client->ob_capacity, new_size);
		new_buf = realloc(client->ob_buf, new_size);
		if (!new_buf) {
			usbfluxd_log(LL_FATAL, "%s: Failed to realloc.", __func__);
			return -1;
		}
		client->ob_buf = new_buf;
		client->ob_capacity = new_size;
	}
	memcpy(client->ob_buf + client->ob_size, buffer, length);
	client->ob_size += length;
	client->events |= POLLOUT;
	return length;
}


static int send_pkt(struct mux_client *client, uint32_t tag, enum usbmuxd_msgtype msg, void *payload, int payload_length)
{
	struct usbmuxd_header hdr;
	hdr.version = client->proto_version;
	hdr.length = sizeof(hdr) + payload_length;
	hdr.message = msg;
	hdr.tag = tag;
	usbfluxd_log(LL_DEBUG, "send_pkt fd %d tag %d msg %d payload_length %d", client->fd, tag, msg, payload_length);

	uint32_t available = client->ob_capacity - client->ob_size;
	/* the output buffer _should_ be large enough, but just in case */
	if(available < hdr.length) {
		unsigned char* new_buf;
		uint32_t new_size = ((client->ob_capacity + hdr.length + 4096) / 4096) * 4096;
		usbfluxd_log(LL_DEBUG, "%s: Enlarging client %d output buffer %d -> %d", __func__, client->fd, client->ob_capacity, new_size);
		new_buf = realloc(client->ob_buf, new_size);
		if (!new_buf) {
			usbfluxd_log(LL_FATAL, "%s: Failed to realloc.", __func__);
			return -1;
		}
		client->ob_buf = new_buf;
		client->ob_capacity = new_size;
	}
	memcpy(client->ob_buf + client->ob_size, &hdr, sizeof(hdr));
	if(payload && payload_length)
		memcpy(client->ob_buf + client->ob_size + sizeof(hdr), payload, payload_length);
	client->ob_size += hdr.length;
	client->events |= POLLOUT;
	return hdr.length;
}

static int send_plist_pkt(struct mux_client *client, uint32_t tag, plist_t plist)
{
	int res = -1;
	char *xml = NULL;
	uint32_t xmlsize = 0;
	plist_to_xml(plist, &xml, &xmlsize);
	if (xml) {
		res = send_pkt(client, tag, MESSAGE_PLIST, xml, xmlsize);
		free(xml);
	} else {
		usbfluxd_log(LL_ERROR, "%s: Could not convert plist to xml", __func__);
	}
	return res;
}

static int send_result(struct mux_client *client, uint32_t tag, uint32_t result)
{
	int res = -1;
	if (client->proto_version == 1) {
		/* XML plist packet */
		plist_t dict = plist_new_dict();
		plist_dict_set_item(dict, "MessageType", plist_new_string("Result"));
		plist_dict_set_item(dict, "Number", plist_new_uint(result));
		res = send_plist_pkt(client, tag, dict);
		plist_free(dict);
	} else {
		/* binary packet */
		res = send_pkt(client, tag, MESSAGE_RESULT, &result, sizeof(uint32_t));
	}
	return res;
}

int client_send_plist_pkt(struct mux_client *client, plist_t plist)
{
	return send_plist_pkt(client, 0, plist);
}

void client_set_remote(struct mux_client *client, struct remote_mux *remote)
{
	client->remote = remote;
}

int client_notify_connect(struct mux_client *client, enum usbmuxd_result result)
{
	usbfluxd_log(LL_SPEW, "client_notify_connect fd %d result %d", client->fd, result);
	if(client->state == CLIENT_DEAD)
		return -1;
	if(client->state != CLIENT_CONNECTING1) {
		usbfluxd_log(LL_ERROR, "client_notify_connect when client %d is not in CONNECTING1 state", client->fd);
		return -1;
	}
	if(send_result(client, client->connect_tag, result) < 0)
		return -1;
	if(result == RESULT_OK) {
		client->state = CLIENT_CONNECTING2;
		client->events = POLLOUT; // wait for the result packet to go through
		// no longer need this
		free(client->ib_buf);
		client->ib_buf = NULL;
	} else {
		client->state = CLIENT_COMMAND;
	}
	return 0;
}

void client_notify_remote_close(struct mux_client *client)
{
	usbfluxd_log(LL_DEBUG, "%s %p", __func__, client);
	client_close(client);
}

static int send_device_list(struct mux_client *client, uint32_t tag)
{
	int res = -1;
	plist_t dict = plist_new_dict();
	plist_t devices = NULL;

	devices = usbmux_remote_get_device_list();

	plist_dict_set_item(dict, "DeviceList", devices);
	res = send_plist_pkt(client, tag, dict);
	plist_free(dict);

	return res;
}

static int send_listener_list(struct mux_client *client, uint32_t tag)
{
	int res = -1;

	plist_t dict = plist_new_dict();
	plist_t listeners = plist_new_array();

	pthread_mutex_lock(&client_list_mutex);
	FOREACH(struct mux_client *lc, &client_list) {
		if (lc->state == CLIENT_LISTEN) {
			plist_t n = NULL;
			plist_t l = plist_new_dict();
			plist_dict_set_item(l, "Blacklisted", plist_new_bool(0));
			n = NULL;
			if (lc->info) {
				n = plist_dict_get_item(lc->info, "BundleID");
			}
			if (n) {
				plist_dict_set_item(l, "BundleID", plist_copy(n));
			}
			plist_dict_set_item(l, "ConnType", plist_new_uint(0));

			n = NULL;
			char *progname = NULL;
			if (lc->info) {
				n = plist_dict_get_item(lc->info, "ProgName");
			}
			if (n) {
				plist_get_string_val(n, &progname);
			}
			if (!progname) {
				progname = strdup("unknown");
			}
			char *idstring = malloc(strlen(progname) + 12);
			sprintf(idstring, "%u-%s", client->number, progname);

			plist_dict_set_item(l, "ID String", plist_new_string(idstring));
			free(idstring);
			plist_dict_set_item(l, "ProgName", plist_new_string(progname));
			free(progname);

			n = NULL;
			uint64_t version = 0;
			if (lc->info) {
				n = plist_dict_get_item(lc->info, "kLibUSBMuxVersion");
			}
			if (n) {
				plist_get_uint_val(n, &version);
			}
			plist_dict_set_item(l, "kLibUSBMuxVersion", plist_new_uint(version));

			plist_array_append_item(listeners, l);
		}
	} ENDFOREACH
	pthread_mutex_unlock(&client_list_mutex);

	plist_dict_set_item(dict, "ListenerList", listeners);
	res = send_plist_pkt(client, tag, dict);
	plist_free(dict);

	return res;
}

static int send_instances(struct mux_client *client, uint32_t tag)
{
	int res = -1;

	plist_t dict = plist_new_dict();
	plist_t instances = usbmux_remote_get_instances();
	plist_dict_set_item(dict, "Instances", instances);
	res = send_plist_pkt(client, tag, dict);
	plist_free(dict);

	return res;
}

static int notify_device_add(struct mux_client *client, plist_t dev)
{
	int res = -1;
	usbfluxd_log(LL_DEBUG, "%s: proto version %d", __func__, client->proto_version);
	if (client->proto_version == 1) {
		/* XML plist packet */
		res = send_plist_pkt(client, 0, dev);
	} else {
		/* binary packet */
		struct usbmuxd_device_record dmsg;
		plist_t node;
		uint64_t u64val = 0;
		char *strval = NULL;

		memset(&dmsg, 0, sizeof(dmsg));

		node = plist_dict_get_item(dev, "DeviceID");
		if (node) {
			plist_get_uint_val(node, &u64val);
			dmsg.device_id = (uint32_t)u64val;
		}

		node = plist_access_path(dev, 2, "Properties", "SerialNumber");
		if (node) {
			strval = NULL;
			plist_get_string_val(node, &strval);
			if (strval) {
				strncpy(dmsg.serial_number, strval, 256);
				free(strval);
			}
		}
		dmsg.serial_number[255] = 0;

		node = plist_access_path(dev, 2, "Properties", "LocationID");
		if (node) {
			u64val = 0;
			plist_get_uint_val(node, &u64val);
			dmsg.location = (uint32_t)u64val;
		}

		node = plist_access_path(dev, 2, "Properties", "ProductID");
		if (node) {
			u64val = 0;
			plist_get_uint_val(node, &u64val);
			dmsg.product_id = (uint16_t)u64val;
		}

		res = send_pkt(client, 0, MESSAGE_DEVICE_ADD, &dmsg, sizeof(dmsg));
	}
	return res;
}

static int notify_device_remove(struct mux_client *client, uint32_t device_id)
{
	int res = -1;
	if (client->proto_version == 1) {
		/* XML plist packet */
		plist_t dict = plist_new_dict();
		plist_dict_set_item(dict, "MessageType", plist_new_string("Detached"));
		plist_dict_set_item(dict, "DeviceID", plist_new_uint(device_id));
		res = send_plist_pkt(client, 0, dict);
		plist_free(dict);
	} else {
		/* binary packet */
		res = send_pkt(client, 0, MESSAGE_DEVICE_REMOVE, &device_id, sizeof(uint32_t));
	}
	return res;
}

static int start_listen(struct mux_client *client)
{
	client->state = CLIENT_LISTEN;
	usbfluxd_log(LL_DEBUG, "Client %d now LISTENING", client->fd);
	plist_t devices = usbmux_remote_get_device_list();	
	uint32_t i;
	int count = 0;
	for (i = 0; i < plist_array_get_size(devices); i++) {
		plist_t dev = plist_array_get_item(devices, i);
		if (notify_device_add(client, dev) < 0) {
			break;
		}
		count++;
	}
	plist_free(devices);

	return count;
}

static char* plist_dict_get_string_val(plist_t dict, const char* key)
{
	if (!dict || plist_get_node_type(dict) != PLIST_DICT)
		return NULL;
	plist_t item = plist_dict_get_item(dict, key);
	if (!item || plist_get_node_type(item) != PLIST_STRING)
		return NULL;
	char *str = NULL;
	plist_get_string_val(item, &str);
	return str;
}

int client_send_packet_data(struct mux_client *client, struct usbmuxd_header *hdr, void *payload, uint32_t payload_size)
{
	int res = send_pkt_raw(client, hdr, sizeof(struct usbmuxd_header));
	if (payload_size > 0) {
		res = send_pkt_raw(client, payload, payload_size);
	}
	return res;
}

static void update_client_info(struct mux_client *client, plist_t dict)
{
	plist_t node = NULL;
	char *strval = NULL;
	uint64_t u64val = 0;
	plist_t info = plist_new_dict();

	node = plist_dict_get_item(dict, "BundleID");
	if (node && (plist_get_node_type(node) == PLIST_STRING)) {
		plist_get_string_val(node, &strval);
		plist_dict_set_item(info, "BundleID", plist_new_string(strval));
		free(strval);
	}

	strval = NULL;
	node = plist_dict_get_item(dict, "ClientVersionString");
	if (node && (plist_get_node_type(node) == PLIST_STRING)) {
		plist_get_string_val(node, &strval);
		plist_dict_set_item(info, "ClientVersionString", plist_new_string(strval));
		free(strval);
	}

	strval = NULL;
	node = plist_dict_get_item(dict, "ProgName");
	if (node && (plist_get_node_type(node) == PLIST_STRING)) {
		plist_get_string_val(node, &strval);
		plist_dict_set_item(info, "ProgName", plist_new_string(strval));
		free(strval);
	}

	u64val = 0;
	node = plist_dict_get_item(dict, "kLibUSBMuxVersion");
	if (node && (plist_get_node_type(node) == PLIST_UINT)) {
		plist_get_uint_val(node, &u64val);
		plist_dict_set_item(info, "kLibUSBMuxVersion", plist_new_uint(u64val));
	}
	plist_free(client->info);
	client->info = info;
}

static int client_command(struct mux_client *client, struct usbmuxd_header *hdr)
{
	int res;
	usbfluxd_log(LL_DEBUG, "Client command in fd %d len %d ver %d msg %d tag %d", client->fd, hdr->length, hdr->version, hdr->message, hdr->tag);

	if(client->state != CLIENT_COMMAND) {
		usbfluxd_log(LL_ERROR, "Client %d command received in the wrong state", client->fd);
		if(send_result(client, hdr->tag, RESULT_BADCOMMAND) < 0)
			return -1;
		client_close(client);
		return -1;
	}

	if((hdr->version != 0) && (hdr->version != 1)) {
		usbfluxd_log(LL_INFO, "Client %d version mismatch: expected 0 or 1, got %d", client->fd, hdr->version);
		send_result(client, hdr->tag, RESULT_BADVERSION);
		return 0;
	}

	struct usbmuxd_connect_request *ch;
	char *payload;
	uint32_t payload_size;

	switch(hdr->message) {
		case MESSAGE_PLIST:
			client->proto_version = 1;
			payload = (char*)(hdr) + sizeof(struct usbmuxd_header);
			payload_size = hdr->length - sizeof(struct usbmuxd_header);
			plist_t dict = NULL;
			plist_from_xml(payload, payload_size, &dict);
			if (!dict) {
				usbfluxd_log(LL_ERROR, "Could not parse plist from payload!");
				return -1;
			} else {
				char *message = NULL;
				plist_t node = plist_dict_get_item(dict, "MessageType");
				if (!node || plist_get_node_type(node) != PLIST_STRING) {
					usbfluxd_log(LL_ERROR, "Could not read valid MessageType node from plist!");
					plist_free(dict);
					return -1;
				}
				plist_get_string_val(node, &message);
				if (!message) {
					usbfluxd_log(LL_ERROR, "Could not extract MessageType from plist!");
					plist_free(dict);
					return -1;
				}
				update_client_info(client, dict);
				usbfluxd_log(LL_DEBUG, "%s: Message is %s client fd %d", __func__, message, client->fd);
				if (!strcmp(message, "Listen")) {
					free(message);
					plist_free(dict);
					if (send_result(client, hdr->tag, 0) < 0)
						return -1;
					return start_listen(client);
				} else if (!strcmp(message, "Connect")) {
					uint64_t val;
					uint16_t portnum = 0;
					uint32_t device_id = 0;
					free(message);
					// get device id
					node = plist_dict_get_item(dict, "DeviceID");
					if (!node) {
						usbfluxd_log(LL_ERROR, "Received connect request without device_id!");
						plist_free(dict);
						if (send_result(client, hdr->tag, RESULT_BADDEV) < 0)
							return -1;
						return 0;
					}
					val = 0;
					plist_get_uint_val(node, &val);
					device_id = (uint32_t)val;

					// get port number
					node = plist_dict_get_item(dict, "PortNumber");
					if (!node) {
						usbfluxd_log(LL_ERROR, "Received connect request without port number!");
						plist_free(dict);
						if (send_result(client, hdr->tag, RESULT_BADCOMMAND) < 0)
							return -1;
						return 0;
					}
					val = 0;
					plist_get_uint_val(node, &val);
					portnum = (uint16_t)val;

					usbfluxd_log(LL_DEBUG, "Client %d connection request to device %d port %d", client->fd, device_id, ntohs(portnum));

					res = usbmux_remote_connect(device_id, hdr->tag, dict, client);
					plist_free(dict);
					if(res < 0) {
						if (send_result(client, hdr->tag, -res) < 0)
							return -1;
					} else {
						client->connect_tag = hdr->tag;
						client->connect_device = device_id;
						client->state = CLIENT_CONNECTING1;
					}
					return 0;
				} else if (!strcmp(message, "ListDevices")) {
					free(message);
					plist_free(dict);
					if (send_device_list(client, hdr->tag) < 0)
						return -1;
					return 0;
				} else if (!strcmp(message, "ListListeners")) {
					free(message);
					plist_free(dict);
					if (send_listener_list(client, hdr->tag) < 0)
						return -1;
					return 0;
				} else if (!strcmp(message, "ReadBUID")) {
					free(message);
					res = usbmux_remote_read_buid(hdr->tag, client);
					plist_free(dict);
					return 0;
				} else if (!strcmp(message, "ReadPairRecord")) {
					free(message);
					char* record_id = plist_dict_get_string_val(dict, "PairRecordID");
					plist_free(dict);
					res = usbmux_remote_read_pair_record(record_id, hdr->tag, client);
					free(record_id);
					if (res < 0)
						return -1;
					return 0;
				} else if (!strcmp(message, "SavePairRecord")) {
					free(message);
					char* record_id = plist_dict_get_string_val(dict, "PairRecordID");
					res = usbmux_remote_save_pair_record(record_id, dict, hdr->tag, client);
					plist_free(dict);
					if (res < 0)
						return -1;
					return 0;
				} else if (!strcmp(message, "DeletePairRecord")) {
					free(message);
					char* record_id = plist_dict_get_string_val(dict, "PairRecordID");
					plist_free(dict);
					res = usbmux_remote_delete_pair_record(record_id, hdr->tag, client);
					if (res < 0)
						return -1;
					return 0;
				} else if (!strcmp(message, "Instances")) {
					free(message);
					plist_free(dict);
					if (send_instances(client, hdr->tag) < 0)
						return -1;
					return 0;
				} else if (!strcmp(message, "AddInstance")) {
					free(message);
					char* hostaddr = plist_dict_get_string_val(dict, "HostAddress");
					if (!hostaddr) {
						usbfluxd_log(LL_ERROR, "Received AddInstance request without host address!");
						plist_free(dict);
						if (send_result(client, hdr->tag, RESULT_BADCOMMAND) < 0)
							return -1;
						return 0;
					}
					uint64_t val;
					uint16_t portnum = 0;
					node = plist_dict_get_item(dict, "PortNumber");
					if (!node) {
						usbfluxd_log(LL_ERROR, "Received AddInstance request without port number!");
						plist_free(dict);
						if (send_result(client, hdr->tag, RESULT_BADCOMMAND) < 0)
							return -1;
						return 0;
					}
					val = 0;
					plist_get_uint_val(node, &val);
					portnum = (uint16_t)val;

					int rv = usbmux_remote_add_remote(hostaddr, portnum);
					if (rv < 0) {
						int rc = RESULT_CONNREFUSED;
						if (rv == -2) {
							usbfluxd_log(LL_ERROR, "Failed to add remote %s:%u (already present)", hostaddr, portnum);
							rc = RESULT_BADDEV;
						} else {
							usbfluxd_log(LL_ERROR, "Failed to add remote %s:%u", hostaddr, portnum);
						}
						free(hostaddr);
						if (send_result(client, hdr->tag, rc) < 0)
							return -1;
						return 0;
					}
					free(hostaddr);
					if (send_result(client, hdr->tag, RESULT_OK) < 0)
						return -1;
					return 0;
				} else if (!strcmp(message, "RemoveInstance")) {
					free(message);
					char* hostaddr = plist_dict_get_string_val(dict, "HostAddress");
					if (!hostaddr) {
						usbfluxd_log(LL_ERROR, "Received RemoveInstance request without host address!");
						plist_free(dict);
						if (send_result(client, hdr->tag, RESULT_BADCOMMAND) < 0)
							return -1;
						return 0;
					}
					uint64_t val;
					uint16_t portnum = 0;
					node = plist_dict_get_item(dict, "PortNumber");
					if (!node) {
						usbfluxd_log(LL_ERROR, "Received RemoveInstance request without port number!");
						plist_free(dict);
						if (send_result(client, hdr->tag, RESULT_BADCOMMAND) < 0)
							return -1;
						return 0;
					}
					val = 0;
					plist_get_uint_val(node, &val);
					portnum = (uint16_t)val;

					if (usbmux_remote_remove_remote(hostaddr, portnum) < 0) {
						usbfluxd_log(LL_ERROR, "Failed to remove remote %s:%u", hostaddr, portnum);
						free(hostaddr);
						if (send_result(client, hdr->tag, RESULT_BADDEV) < 0)
							return -1;
						return 0;
					}
					free(hostaddr);
					if (send_result(client, hdr->tag, RESULT_OK) < 0)
						return -1;
					return 0;
				} else {
					usbfluxd_log(LL_ERROR, "Unexpected command '%s' received!", message);
					free(message);
					plist_free(dict);
					if (send_result(client, hdr->tag, RESULT_BADCOMMAND) < 0)
						return -1;
					return 0;
				}
			}
			// should not be reached?!
			return -1;
		case MESSAGE_LISTEN:
			if(send_result(client, hdr->tag, 0) < 0)
				return -1;
			return start_listen(client);
		case MESSAGE_CONNECT:
			ch = (void*)hdr;
			usbfluxd_log(LL_DEBUG, "Client %d connection request to device %d port %d", client->fd, ch->device_id, ntohs(ch->port));
			plist_t msg = plist_new_dict();
			plist_dict_set_item(msg, "MessageType", plist_new_string("Connect"));
			plist_dict_set_item(msg, "DeviceID", plist_new_uint(ch->device_id));
			plist_dict_set_item(msg, "PortNumber", plist_new_uint(ch->port));
			res = usbmux_remote_connect(ch->device_id, hdr->tag, msg, client);
			plist_free(msg);
			if(res < 0) {
				if(send_result(client, hdr->tag, -res) < 0)
					return -1;
			} else {
				client->connect_tag = hdr->tag;
				client->connect_device = ch->device_id;
				client->state = CLIENT_CONNECTING1;
			}
			return 0;
		default:
			usbfluxd_log(LL_ERROR, "Client %d invalid command %d", client->fd, hdr->message);
			if(send_result(client, hdr->tag, RESULT_BADCOMMAND) < 0)
				return -1;
			return 0;
	}
	return -1;
}

static void process_send(struct mux_client *client)
{
	usbfluxd_log(LL_DEBUG, "%s", __func__);
	int res;
	if (!client->ob_size) {
		usbfluxd_log(LL_WARNING, "Client %d OUT process but nothing to send?", client->fd);
		client->events &= ~POLLOUT;
		return;
	}
	res = send(client->fd, client->ob_buf, client->ob_size, 0);
	usbfluxd_log(LL_DEBUG, "%s: sent %d (of %d)", __func__, res, client->ob_size);
	if (res <= 0) {
		usbfluxd_log(LL_ERROR, "Send to client fd %d failed: %d %s", client->fd, res, strerror(errno));
		client_close(client);
		return;
	}
	if ((uint32_t)res == client->ob_size) {
		client->ob_size = 0;
		client->events &= ~POLLOUT;
		if (client->state == CLIENT_CONNECTING2) {
			usbfluxd_log(LL_DEBUG, "Client %d switching to CONNECTED state, remote %d", client->fd, client->remote->fd);
			client->state = CLIENT_CONNECTED;
			client->events = client->devents;
			// no longer need this
			free(client->ob_buf);
			client->ob_buf = NULL;
			client->events |= POLLIN; //POLLOUT;
		}
	} else {
		client->ob_size -= res;
		memmove(client->ob_buf, client->ob_buf + res, client->ob_size);
	}
}
static void process_recv(struct mux_client *client)
{
	usbfluxd_log(LL_DEBUG, "%s fd %d", __func__, client->fd);
	int res;
	int did_read = 0;
	if(client->ib_size < sizeof(struct usbmuxd_header)) {
		res = recv(client->fd, client->ib_buf + client->ib_size, sizeof(struct usbmuxd_header) - client->ib_size, 0);
		if(res <= 0) {
			if(res < 0)
				usbfluxd_log(LL_ERROR, "Receive from client fd %d failed: %s", client->fd, strerror(errno));
			else
				usbfluxd_log(LL_INFO, "Client %d connection closed", client->fd);
			client_close(client);
			return;
		}
		client->ib_size += res;
		if(client->ib_size < sizeof(struct usbmuxd_header))
			return;
		did_read = 1;
	}
	struct usbmuxd_header *hdr = (void*)client->ib_buf;
	if(hdr->length > client->ib_capacity) {
		usbfluxd_log(LL_INFO, "Client %d message is too long (%d bytes)", client->fd, hdr->length);
		client_close(client);
		return;
	}
	if(hdr->length < sizeof(struct usbmuxd_header)) {
		usbfluxd_log(LL_ERROR, "Client %d message is too short (%d bytes)", client->fd, hdr->length);
		client_close(client);
		return;
	}
	if(client->ib_size < hdr->length) {
		if(did_read)
			return; //maybe we would block, so defer to next loop
		res = recv(client->fd, client->ib_buf + client->ib_size, hdr->length - client->ib_size, 0);
		if(res < 0) {
			usbfluxd_log(LL_ERROR, "Receive from client fd %d failed: %s", client->fd, strerror(errno));
			client_close(client);
			return;
		} else if(res == 0) {
			usbfluxd_log(LL_INFO, "Client %d connection closed", client->fd);
			client_close(client);
			return;
		}
		client->ib_size += res;
		if(client->ib_size < hdr->length)
			return;
	}
	client_command(client, hdr);
	client->ib_size = 0;
}

void client_process(int fd, short events)
{
	struct mux_client *client = NULL;
	pthread_mutex_lock(&client_list_mutex);
	FOREACH(struct mux_client *lc, &client_list) {
		if(lc->fd == fd) {
			client = lc;
			break;
		}
	} ENDFOREACH
	pthread_mutex_unlock(&client_list_mutex);

	if(!client) {
		usbfluxd_log(LL_DEBUG, "client_process: fd %d not found in client list", fd);
		return;
	}

	if(client->state == CLIENT_CONNECTED) {
		usbfluxd_log(LL_DEBUG, "%s in CONNECTED state, fd=%d", __func__, fd);
		if(events & POLLIN) {
			// read from client
			if ((int64_t)client->remote->ob_capacity - (int64_t)client->remote->ob_size <= 0) {
				usbfluxd_log(LL_WARNING, "%s: ib_buf buffer is full, let's try this next loop iteration", __func__);
				return;
			}
			usbfluxd_log(LL_DEBUG, "read from client %d to remote buffer", client->fd);
			int s = client_read(client, client->remote->ob_buf + client->remote->ob_size, client->remote->ob_capacity - client->remote->ob_size);
			usbfluxd_log(LL_DEBUG, "client read returned %d", s);
			if (s > 0) {
				client->remote->ob_size += s;
				client->remote->events |= POLLOUT;
				client->events &= ~POLLIN;
			} else {
				usbfluxd_log(LL_INFO, "Client %d connection closed", client->fd);
				client_close(client);
				return;
			}
		} else if (events & POLLOUT) {
			usbfluxd_log(LL_DEBUG, "writing to client %d from remote buffer", client->fd);
			if (client->remote->ib_size > 0) {
				usbfluxd_log(LL_DEBUG, "sending %d bytes to client", client->remote->ib_size);
				int res = client_write(client, client->remote->ib_buf, client->remote->ib_size);
				if(res <= 0) {
					usbfluxd_log(LL_ERROR, "Send to client fd %d failed: %d %s", client->fd, res, strerror(errno));
					client_close(client);
					return;
				}
				if((uint32_t)res == client->remote->ib_size) {
					client->remote->ib_size = 0;
					client->events &= ~POLLOUT;
					client->events |= POLLIN;
				} else {
					client->remote->ib_size -= res;
					memmove(client->remote->ib_buf, client->remote->ib_buf + res, client->remote->ib_size);
				}
			}
		}
	} else {
		if(events & POLLIN) {
			process_recv(client);
		} else if(events & POLLOUT) { //not both in case client died as part of process_recv
			process_send(client);
		}
	}
}

void client_device_add(plist_t dev)
{
	pthread_mutex_lock(&client_list_mutex);
	usbfluxd_log(LL_DEBUG, "%s", __func__);
	FOREACH(struct mux_client *client, &client_list) {
		if (client->state == CLIENT_LISTEN)
			notify_device_add(client, dev);
	} ENDFOREACH
	pthread_mutex_unlock(&client_list_mutex);
}

void client_device_remove(uint32_t device_id)
{
	pthread_mutex_lock(&client_list_mutex);
	usbfluxd_log(LL_DEBUG, "client_device_remove: id %d", device_id);
	FOREACH(struct mux_client *client, &client_list) {
		if (client->state == CLIENT_LISTEN)
			notify_device_remove(client, device_id);
	} ENDFOREACH
	pthread_mutex_unlock(&client_list_mutex);
}

void client_remote_unset(struct remote_mux *remote)
{
	pthread_mutex_lock(&client_list_mutex);
	usbfluxd_log(LL_DEBUG, "%s: %p", __func__, remote);
	FOREACH(struct mux_client *client, &client_list) {
		if (client->remote == remote) {
			client->remote = NULL;
		}
	} ENDFOREACH
	pthread_mutex_unlock(&client_list_mutex);
}

void client_init(void)
{
	usbfluxd_log(LL_DEBUG, "client_init");
	collection_init(&client_list);
	pthread_mutex_init(&client_list_mutex, NULL);
}

void client_shutdown(void)
{
	usbfluxd_log(LL_DEBUG, "client_shutdown");
	FOREACH(struct mux_client *client, &client_list) {
		client_close(client);
	} ENDFOREACH
	pthread_mutex_destroy(&client_list_mutex);
	collection_free(&client_list);
}
