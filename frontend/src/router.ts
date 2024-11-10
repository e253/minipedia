import { createRouter, createWebHistory } from 'vue-router'
import Home from "./Home.vue"

export const router = createRouter({
  history: createWebHistory(import.meta.env.BASE_URL),
  routes: [
    {
      path: '/',
      name: 'home',
      component: Home,
    },
  ],
})
