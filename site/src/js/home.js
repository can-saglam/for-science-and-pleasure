// The reel holds still for anyone who has asked for less motion.
if (matchMedia("(prefers-reduced-motion: reduce)").matches) document.querySelector(".fan video")?.pause();
